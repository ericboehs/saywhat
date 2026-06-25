/// A single-track audio source — the hardware seam.
///
/// Concrete implementations wrap `AVAudioEngine` (mic) and `ScreenCaptureKit`
/// (system); tests inject a fake that replays fixture frames. Per the
/// separate-tracks invariant, each instance owns exactly one ``CaptureSource``.
/// See QUALITY.md §5.
public protocol AudioCapture: Sendable {
    /// The single track this instance captures.
    var source: CaptureSource { get }

    /// Begin capture, yielding 16 kHz mono Float32 frames until ``stop()``.
    func start() async throws -> AsyncStream<AudioFrame>

    /// Stop capture and release the device.
    func stop() async
}

/// Durable, append-only sink for one track's audio — the storage seam.
///
/// The concrete implementation streams AAC/m4a to disk continuously, rotating
/// segments per ``SegmentRotationPolicy`` so an ASR or LLM crash can never lose
/// the recording or take down capture. See DESIGN.md §4, §10.
public protocol DurableAudioWriter: Sendable {
    /// Append a frame, persisting it promptly enough to survive a crash.
    func append(_ frame: AudioFrame) async throws

    /// Flush and close the recording, writing the finalize marker.
    func finalize() async throws
}
