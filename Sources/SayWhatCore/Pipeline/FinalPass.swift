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

    private let reader: RecordingReader
    private let diarizer: any Diarizer
    private let merger: TranscriptMerger
    private let makeTranscriber: MakeTranscriber
    private let budget: Budget

    /// Generous default watchdog: `4×` realtime, floored at a minute. The whole
    /// final pass runs well under realtime in practice, so this only ever fires
    /// on a true stall.
    public static let defaultBudget: Budget = { audio in
        max(.seconds(60), audio * 4)
    }

    public init(
        reader: RecordingReader = RecordingReader(),
        diarizer: any Diarizer,
        merger: TranscriptMerger = TranscriptMerger(),
        budget: @escaping Budget = FinalPass.defaultBudget,
        makeTranscriber: @escaping MakeTranscriber
    ) {
        self.reader = reader
        self.diarizer = diarizer
        self.merger = merger
        self.budget = budget
        self.makeTranscriber = makeTranscriber
    }

    /// Produce the authoritative transcript for a finalized `session`.
    ///
    /// - Parameter onProgress: called on the calling task as each ``Phase``
    ///   begins, for UI narration. Optional.
    public func run(
        _ session: RecordingSession,
        onProgress: (@Sendable (Phase) -> Void)? = nil
    ) async throws -> Transcript {
        let micFrames = try await collect(.microphone, in: session)
        let systemFrames = try await collect(.system, in: session)

        onProgress?(.transcribing(.microphone))
        let mic = try await transcribe(.microphone, micFrames)

        onProgress?(.transcribing(.system))
        let system = try await transcribe(.system, systemFrames)

        onProgress?(.diarizing)
        let remoteSpeakers = try await diarize(systemFrames)

        onProgress?(.merging)
        return merger.merge(mic: mic, system: system, remoteSpeakers: remoteSpeakers)
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
