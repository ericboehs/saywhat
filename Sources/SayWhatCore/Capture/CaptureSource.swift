/// One of the two audio tracks SayWhat keeps **separate end to end**.
///
/// The channel split is itself free, perfect coarse diarization:
/// ``microphone`` is the local speaker (you); ``system`` is everyone else.
/// Mixing the two into one stream is the mistake that collapses all speakers
/// onto a single label, so the two sources never share a capture, storage, or
/// transcriber instance. See DESIGN.md §4.
public enum CaptureSource: String, Sendable, CaseIterable, Codable {
    /// Local microphone, captured via `AVAudioEngine` — the local speaker.
    case microphone

    /// System audio (call output, or the room), captured via
    /// `ScreenCaptureKit` — the remote participants.
    case system
}
