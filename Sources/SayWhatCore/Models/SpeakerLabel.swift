import Foundation

/// Who a transcript segment is attributed to. Channel-coarse: the mic channel is
/// always the local user, and everything on the system channel is a remote
/// speaker, split into slots by the diarizer.
public enum SpeakerLabel: Sendable, Equatable, Hashable {
    /// The local user (the mic channel).
    case you
    /// A remote speaker, by the diarizer's slot/cluster index.
    case remote(Int)
}
