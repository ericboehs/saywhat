/// How a session captures audio, chosen per recording. Determines which
/// ``CaptureSource``s are active. See DESIGN.md §4.
public enum CaptureMode: String, Sendable, CaseIterable, Codable {
    /// Mic + system audio as two separate tracks. The default.
    case videoCall

    /// Microphone only (one device capturing the room); diarization splits
    /// voices from the single track. No system track.
    case inPerson

    /// The capture sources active in this mode, in a stable order.
    public var sources: [CaptureSource] {
        switch self {
        case .videoCall: [.microphone, .system]
        case .inPerson: [.microphone]
        }
    }

    /// Whether this mode records the system-audio track.
    public var capturesSystemAudio: Bool {
        sources.contains(.system)
    }
}
