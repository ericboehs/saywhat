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

    /// Everything the pass produced: the authoritative transcript plus the
    /// persistent ``Voiceprint`` each remote slot resolved to. The mapping lets
    /// the UI offer to rename a speaker — writing the chosen name back onto its
    /// voiceprint teaches every future meeting to recognize them by it. Empty
    /// when identity resolution was skipped (no store wired, or no embeddings).
    public struct Outcome: Sendable, Equatable {
        /// The merged, timeline-ordered authoritative record.
        public let transcript: Transcript
        /// Remote diarizer slot → the voiceprint it matched or minted.
        public let speakers: [Int: Voiceprint]

        public init(transcript: Transcript, speakers: [Int: Voiceprint] = [:]) {
            self.transcript = transcript
            self.speakers = speakers
        }
    }

    private let reader: RecordingReader
    private let diarizer: any Diarizer
    private let merger: TranscriptMerger
    private let makeTranscriber: MakeTranscriber
    private let budget: Budget
    private let store: VoiceprintStore?
    private let resolver: SpeakerResolver
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
    ///   - resolver: the slot → identity policy. Defaults to a conservative match.
    ///   - embedder: extracts the `wespeaker_v2` identity vector for a slot's
    ///     audio — the one space live and final recognition share. `nil` (or no
    ///     store) skips identity resolution entirely (generic `Speaker N` labels).
    public init(
        reader: RecordingReader = RecordingReader(),
        diarizer: any Diarizer,
        merger: TranscriptMerger = TranscriptMerger(),
        budget: @escaping Budget = FinalPass.defaultBudget,
        store: VoiceprintStore? = nil,
        resolver: SpeakerResolver = SpeakerResolver(),
        embedder: (any SpeakerEmbedder)? = nil,
        makeTranscriber: @escaping MakeTranscriber
    ) {
        self.reader = reader
        self.diarizer = diarizer
        self.merger = merger
        self.budget = budget
        self.store = store
        self.resolver = resolver
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
        let speakers = await resolveIdentities(remoteSpeakers, system: systemFrames)
        let transcript = merger.merge(
            mic: mic,
            system: system,
            remoteSpeakers: remoteSpeakers,
            names: speakers.mapValues(\.name)
        )
        return Outcome(transcript: transcript, speakers: speakers)
    }

    /// Resolve each diarized remote slot to a persistent identity, minting and
    /// persisting a new ``Voiceprint`` for anyone unrecognized, and return the
    /// slot → voiceprint map. The merge takes display names from it; the UI keeps
    /// the voiceprints so a rename can write back to the matched row.
    ///
    /// Identity comes from a `wespeaker_v2` vector re-extracted from each slot's
    /// system audio — not the diarizer's internal cluster embeddings, which live
    /// in an incomparable space — so a voiceprint stays portable to the live namer
    /// (DESIGN.md §6). A slot with too little audio to embed is left unresolved.
    ///
    /// A storage error degrades to generic labels rather than failing the pass:
    /// the authoritative transcript is the durable output and must survive a
    /// voiceprint-DB hiccup (the audio-is-durable tenet, applied to its derived
    /// record). Skipped entirely when no store or embedder is wired.
    private func resolveIdentities(
        _ timeline: SpeakerTimeline,
        system frames: [AudioFrame]
    ) async -> [Int: Voiceprint] {
        guard let store, let embedder else { return [:] }
        let embeddings = await identityEmbeddings(timeline, system: frames, using: embedder)
        guard !embeddings.isEmpty,
              let speakers = try? Self.resolve(embeddings, in: store, with: resolver)
        else { return [:] }
        return speakers
    }

    /// Re-embed each remote slot's system audio into the shared identity space,
    /// dropping slots too short to carry a stable voiceprint. Slots are walked in
    /// order so the result is deterministic.
    private func identityEmbeddings(
        _ timeline: SpeakerTimeline,
        system frames: [AudioFrame],
        using embedder: any SpeakerEmbedder
    ) async -> [Int: [Float]] {
        let slots = Set(timeline.turns.map(\.speaker)).sorted()
        var embeddings: [Int: [Float]] = [:]
        for slot in slots {
            let samples = SpeakerAudio.samples(forSlot: slot, in: timeline, from: frames)
            guard samples.count >= Self.minIdentitySamples else { continue }
            if let vector = try? await embedder.embedding(for: samples) {
                embeddings[slot] = vector
            }
        }
        return embeddings
    }

    /// The throwing core of identity resolution, split out so the call site can
    /// degrade a failure to generic labels in one place.
    private static func resolve(
        _ embeddings: [Int: [Float]],
        in store: VoiceprintStore,
        with resolver: SpeakerResolver
    ) throws -> [Int: Voiceprint] {
        let resolution = try resolver.resolve(embeddings, against: store.all())
        for voiceprint in resolution.minted {
            try store.save(voiceprint)
        }
        return resolution.bySlot
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
