/// Turns one track's audio into a live, readable transcript — the ASR seam.
///
/// Each instance transcribes exactly one ``CaptureSource``: mic and system
/// never share a transcriber, so the channel split survives end to end as
/// coarse diarization (the separate-tracks invariant). Concrete implementations
/// wrap Apple's `SpeechTranscriber` for the live path and FluidAudio Parakeet
/// for the batch final pass; tests inject a fake that replays canned segments.
///
/// Keeping every recognizer behind this protocol is what makes the model
/// swappable — don't leak a concrete engine type past it (CLAUDE.md invariants,
/// DESIGN.md §5, §14).
public protocol Transcriber: Sendable {
    /// The single track this instance transcribes.
    var source: CaptureSource { get }

    /// Transcribe `frames` until the stream finishes, yielding segments as the
    /// recognizer refines them: zero or more **volatile** segments followed by a
    /// **final** one per utterance (see ``TranscriptSegment``).
    ///
    /// The returned stream finishes once all input audio has been processed. It
    /// may finish with an error if the recognizer fails, but — per the
    /// durability invariant — a transcription failure must never take down
    /// capture or lose the recording; the caller drains this independently.
    func transcribe(
        _ frames: AsyncStream<AudioFrame>
    ) async throws -> AsyncThrowingStream<TranscriptSegment, Error>
}
