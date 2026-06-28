import Foundation

/// Runs the **final pass** end to end: re-transcribe a finished session's saved
/// audio with the batch recognizer, diarize the system track offline, and merge
/// the two into the authoritative ``Transcript`` (DESIGN.md §3, §14 Phase 3).
///
/// This is the orchestration seam that ties the proven pieces together —
/// ``RecordingReader`` (saved AAC → frames), a batch ``Transcriber`` per track,
/// an offline ``Diarizer`` for the remote speakers, and ``TranscriptMerger``.
/// It depends only on those protocols and value types, never a concrete model,
/// so the whole flow is unit-testable with fakes; the real engines are injected
/// by the app (Parakeet + offline pyannote). Each track is decoded once and held
/// in memory for the pass — bounded by meeting length, simpler than re-decoding.
public struct FinalPass: Sendable {
    /// Makes the batch ``Transcriber`` for one track. A factory (not a single
    /// instance) because each ``Transcriber`` is bound to one ``CaptureSource``.
    public typealias MakeTranscriber = @Sendable (CaptureSource) -> any Transcriber

    /// Maps a track's audio length to the watchdog budget for an engine stage
    /// over it. Audio-proportional (with a floor) so a two-hour meeting never
    /// false-trips while a genuine deadlock still surfaces as an error.
    public typealias Budget = @Sendable (Duration) -> Duration

    /// A coarse stage, reported as the pass advances so the UI can narrate it.
    public enum Phase: Sendable, Equatable {
        /// Re-transcribing one track's saved audio.
        case transcribing(CaptureSource)
        /// Splitting the system track's remote speakers.
        case diarizing
        /// Folding both tracks into the authoritative transcript.
        case merging
    }

    /// Everything the pass produced: the authoritative transcript plus how each
    /// identity **group** resolved — a matched ``Person`` or a fresh un-named mint.
    /// The mapping lets the UI offer to name a speaker; naming binds that group's
    /// exemplar to a person, teaching every future meeting to recognize them.
    /// Empty when identity resolution was skipped (no store wired, or no embeddings).
    public struct Outcome: Sendable, Equatable {
        /// The merged, timeline-ordered authoritative record.
        public let transcript: Transcript
        /// Identity group → how it resolved (matched person or mint). The groups
        /// come from re-segmenting the diarizer's slots by voice, so two people the
        /// diarizer fused into one slot surface as two distinct groups here.
        public let speakers: [Int: ResolvedSpeaker]
        /// Utterance id → that remote utterance's *own* voice vector (the embedded
        /// turn it overlaps most), so a single mis-grouped segment can be reassigned
        /// and have its voice bound to the right person — even when its group's
        /// exemplar belongs to someone else. Mic (`you`) utterances carry none.
        public let utteranceVoiceprints: [Int: Voiceprint]

        public init(
            transcript: Transcript,
            speakers: [Int: ResolvedSpeaker] = [:],
            utteranceVoiceprints: [Int: Voiceprint] = [:]
        ) {
            self.transcript = transcript
            self.speakers = speakers
            self.utteranceVoiceprints = utteranceVoiceprints
        }
    }

    private let reader: RecordingReader
    private let diarizer: any Diarizer
    private let merger: TranscriptMerger
    private let makeTranscriber: MakeTranscriber
    private let budget: Budget
    private let store: VoiceprintStore?
    private let resegmenter: SpeakerResegmenter
    private let embedder: (any SpeakerEmbedder)?

    /// Minimum system audio a slot needs before we trust an identity embedding
    /// from it — short interjections don't carry a stable voiceprint. One second
    /// at the model's 16 kHz rate.
    private static let minIdentitySamples = 16000

    /// Generous default watchdog: `4×` realtime, floored at a minute. The whole
    /// final pass runs well under realtime in practice, so this only ever fires
    /// on a true stall.
    public static let defaultBudget: Budget = { audio in
        max(.seconds(60), audio * 4)
    }

    /// - Parameters:
    ///   - store: the persistent voiceprint directory. When supplied, remote
    ///     speakers are resolved to (and minted into) it; `nil` skips identity
    ///     resolution entirely (generic `Speaker N` labels).
    ///   - resegmenter: the re-segment-by-voice + identity policy. Defaults to a
    ///     conservative match; its threshold also governs voice clustering.
    ///   - embedder: extracts the `wespeaker_v2` identity vector for a turn's
    ///     audio — the one space live and final recognition share. `nil` (or no
    ///     store) skips identity resolution entirely (generic `Speaker N` labels).
    public init(
        reader: RecordingReader = RecordingReader(),
        diarizer: any Diarizer,
        merger: TranscriptMerger = TranscriptMerger(),
        budget: @escaping Budget = FinalPass.defaultBudget,
        store: VoiceprintStore? = nil,
        resegmenter: SpeakerResegmenter = SpeakerResegmenter(),
        embedder: (any SpeakerEmbedder)? = nil,
        makeTranscriber: @escaping MakeTranscriber
    ) {
        self.reader = reader
        self.diarizer = diarizer
        self.merger = merger
        self.budget = budget
        self.store = store
        self.resegmenter = resegmenter
        self.embedder = embedder
        self.makeTranscriber = makeTranscriber
    }

    /// Produce the authoritative transcript for a finalized `session`.
    ///
    /// - Parameter onProgress: called on the calling task as each ``Phase``
    ///   begins, for UI narration. Optional.
    public func run(
        _ session: RecordingSession,
        onProgress: (@Sendable (Phase) -> Void)? = nil
    ) async throws -> Outcome {
        let micFrames = try await collect(.microphone, in: session)
        let systemFrames = try await collect(.system, in: session)

        onProgress?(.transcribing(.microphone))
        let mic = try await transcribe(.microphone, micFrames)

        onProgress?(.transcribing(.system))
        let system = try await transcribe(.system, systemFrames)

        onProgress?(.diarizing)
        let remoteSpeakers = try await diarize(systemFrames)

        onProgress?(.merging)
        let resegmented = await resegment(remoteSpeakers, system: systemFrames)
        let transcript = merger.merge(
            mic: mic,
            system: system,
            remoteSpeakers: resegmented.resegmentation.timeline,
            names: resegmented.resegmentation.speakers.mapValues(\.name)
        )
        return Outcome(
            transcript: transcript,
            speakers: resegmented.resegmentation.speakers,
            utteranceVoiceprints: Self.utteranceVoiceprints(
                for: transcript,
                timeline: resegmented.resegmentation.timeline,
                embeddings: resegmented.embeddings
            )
        )
    }

    /// Attribute each remote utterance its *own* voice vector: the embedded turn of
    /// the utterance's group that overlaps it most in time. This is the segment's
    /// representative voiceprint — distinct from the group's exemplar — so a
    /// mis-grouped segment can be reassigned to (and teach) the right person even
    /// when its group resolved to someone else. Mic utterances and utterances no
    /// embedded turn covers are simply absent.
    private static func utteranceVoiceprints(
        for transcript: Transcript,
        timeline: SpeakerTimeline,
        embeddings: [Int: [Float]]
    ) -> [Int: Voiceprint] {
        guard !embeddings.isEmpty else { return [:] }
        var result: [Int: Voiceprint] = [:]
        for utterance in transcript.utterances {
            guard case let .remote(group) = utterance.speaker else { continue }
            var best: (vector: [Float], overlap: Double)?
            for (index, turn) in timeline.turns.enumerated() {
                guard turn.speaker == group, let vector = embeddings[index] else { continue }
                let seconds = Self.overlapSeconds(utterance.range, turn.range)
                if seconds > (best?.overlap ?? 0) {
                    best = (vector, seconds)
                }
            }
            if let best {
                result[utterance.id] = Voiceprint(embedding: best.vector)
            }
        }
        return result
    }

    /// Seconds two timeline ranges overlap, `0` when they're disjoint.
    private static func overlapSeconds(_ lhs: Range<Duration>, _ rhs: Range<Duration>) -> Double {
        let lower = max(lhs.lowerBound, rhs.lowerBound)
        let upper = min(lhs.upperBound, rhs.upperBound)
        return upper > lower ? (upper - lower).seconds : 0
    }

    /// Re-segment the diarized timeline by **voice** and resolve each resulting
    /// group to an identity — a recognized ``Person`` or a fresh un-named mint —
    /// returning the re-keyed timeline and the group → resolution map. This is what
    /// pulls apart a slot the diarizer fused across two voices (the Theo+MKBHD
    /// failure): turns are embedded individually, clustered by voice, and only then
    /// matched to people (docs/speaker-identity-resegmentation.md). The merge takes
    /// its segmentation *and* display names from the result; the UI keeps the
    /// resolutions so naming a group can bind its exemplar to a person. Mints are
    /// **not** persisted here: an un-named speaker stays in memory until the user
    /// names it, so the directory never fills with orphan `Speaker N` rows
    /// (docs/speaker-identity-exemplars.md).
    ///
    /// Identity comes from a `wespeaker_v2` vector re-extracted from each turn's
    /// system audio — not the diarizer's internal cluster embeddings, which live
    /// in an incomparable space — so a voiceprint stays portable to the live namer
    /// (DESIGN.md §6). A turn with too little audio to embed is attached to a
    /// neighbor's group by the re-segmenter.
    ///
    /// A storage error degrades to the diarizer's own segmentation with generic
    /// labels rather than failing the pass: the authoritative transcript is the
    /// durable output and must survive a voiceprint-DB hiccup (the audio-is-durable
    /// tenet, applied to its derived record). When no store or embedder is wired,
    /// the diarizer's timeline passes through unchanged.
    private func resegment(
        _ timeline: SpeakerTimeline,
        system frames: [AudioFrame]
    ) async -> (resegmentation: SpeakerResegmenter.Resegmentation, embeddings: [Int: [Float]]) {
        let passthrough = SpeakerResegmenter.Resegmentation(timeline: timeline, speakers: [:])
        guard let store, let embedder else { return (passthrough, [:]) }
        guard let directory = try? store.enrolledPersons() else { return (passthrough, [:]) }
        let embeddings = await turnEmbeddings(timeline, system: frames, using: embedder)
        let resegmentation = resegmenter.resegment(
            turns: timeline.turns,
            embeddings: embeddings,
            against: directory
        )
        return (resegmentation, embeddings)
    }

    /// Embed each turn's system audio into the shared identity space, keyed by the
    /// turn's index, dropping turns too short to carry a stable voiceprint. Turns
    /// are walked in order so the result is deterministic.
    private func turnEmbeddings(
        _ timeline: SpeakerTimeline,
        system frames: [AudioFrame],
        using embedder: any SpeakerEmbedder
    ) async -> [Int: [Float]] {
        var embeddings: [Int: [Float]] = [:]
        for (index, turn) in timeline.turns.enumerated() {
            let samples = SpeakerAudio.samples(for: turn, from: frames)
            guard samples.count >= Self.minIdentitySamples else { continue }
            if let vector = try? await embedder.embedding(for: samples) {
                embeddings[index] = vector
            }
        }
        return embeddings
    }

    /// Decode one track's saved segments into an in-memory frame buffer.
    private func collect(
        _ source: CaptureSource,
        in session: RecordingSession
    ) async throws -> [AudioFrame] {
        var frames: [AudioFrame] = []
        for try await frame in reader.frames(for: source, in: session) {
            frames.append(frame)
        }
        return frames
    }

    /// Batch-transcribe one track under the watchdog; an empty track yields no
    /// segments. A stalled recognizer fails with ``TimeoutError`` rather than
    /// hanging the pass.
    private func transcribe(
        _ source: CaptureSource,
        _ frames: [AudioFrame]
    ) async throws -> [TranscriptSegment] {
        guard !frames.isEmpty else { return [] }
        let make = makeTranscriber
        return try await withTimeout(
            budget(Self.duration(of: frames)),
            label: "transcribe(\(source))"
        ) {
            var segments: [TranscriptSegment] = []
            for try await segment in try await make(source).transcribe(Self.stream(frames)) {
                segments.append(segment)
            }
            return segments
        }
    }

    /// Offline-diarize the system track into its final remote-speaker timeline
    /// (the last snapshot the diarizer emits) under the watchdog; an empty track
    /// yields none.
    private func diarize(_ frames: [AudioFrame]) async throws -> SpeakerTimeline {
        guard !frames.isEmpty else { return SpeakerTimeline() }
        let diarizer = diarizer
        return try await withTimeout(budget(Self.duration(of: frames)), label: "diarize") {
            var timeline = SpeakerTimeline()
            for await snapshot in try await diarizer.diarize(Self.stream(frames)) {
                timeline = snapshot
            }
            return timeline
        }
    }

    /// Wall-clock span of an in-memory track: where its last frame ends.
    private static func duration(of frames: [AudioFrame]) -> Duration {
        guard let last = frames.last else { return .zero }
        return last.startOffset + last.duration
    }

    /// Replay an in-memory frame buffer as the non-throwing stream the engines
    /// consume (the audio was already decoded by ``collect(_:in:)``).
    private static func stream(_ frames: [AudioFrame]) -> AsyncStream<AudioFrame> {
        AsyncStream { continuation in
            for frame in frames {
                continuation.yield(frame)
            }
            continuation.finish()
        }
    }
}
