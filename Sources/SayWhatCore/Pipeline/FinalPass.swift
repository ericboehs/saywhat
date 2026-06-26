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

    public init(
        reader: RecordingReader = RecordingReader(),
        diarizer: any Diarizer,
        merger: TranscriptMerger = TranscriptMerger(),
        makeTranscriber: @escaping MakeTranscriber
    ) {
        self.reader = reader
        self.diarizer = diarizer
        self.merger = merger
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

    /// Batch-transcribe one track; an empty track yields no segments.
    private func transcribe(
        _ source: CaptureSource,
        _ frames: [AudioFrame]
    ) async throws -> [TranscriptSegment] {
        guard !frames.isEmpty else { return [] }
        var segments: [TranscriptSegment] = []
        for try await segment in try await makeTranscriber(source).transcribe(Self.stream(frames)) {
            segments.append(segment)
        }
        return segments
    }

    /// Offline-diarize the system track into its final remote-speaker timeline
    /// (the last snapshot the diarizer emits); an empty track yields none.
    private func diarize(_ frames: [AudioFrame]) async throws -> SpeakerTimeline {
        guard !frames.isEmpty else { return SpeakerTimeline() }
        var timeline = SpeakerTimeline()
        for await snapshot in try await diarizer.diarize(Self.stream(frames)) {
            timeline = snapshot
        }
        return timeline
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
