import Foundation

/// Splits one audio track into speaker turns. Like ``Transcriber``, it consumes
/// a frame stream and is swappable behind this protocol — FluidAudio Sortformer
/// for the live path, offline pyannote for the final pass (DESIGN.md §6).
///
/// Per the design's channel-diarization tenet, the *live* diarizer runs on the
/// **system track only**: the mic channel is already "you", so the model's job
/// is just to split the multiple remote speakers within the system track.
public protocol Diarizer: Sendable {
    /// Feed one track's frames in; receive evolving ``SpeakerTimeline``
    /// snapshots as the engine refines who spoke when. Each emission is the full
    /// known timeline to date (later snapshots supersede earlier ones), so a
    /// consumer keeps only the latest. Finishes when the input stream ends.
    func diarize(_ frames: AsyncStream<AudioFrame>) async throws -> AsyncStream<SpeakerTimeline>
}
