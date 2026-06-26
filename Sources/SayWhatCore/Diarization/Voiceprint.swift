import Foundation

/// A persisted, named speaker — the unit of **cross-session identity**. A
/// voiceprint pairs a stable id and display name with the 256-dim speaker
/// embedding FluidAudio's `SpeakerManager` extracts; matching a meeting's
/// observed embeddings against the enrolled set is how "Eric" and "Ashley" get
/// recognized in every future meeting instead of being relabelled per session
/// (DESIGN.md §6 "Persistent identity").
///
/// This is our own value type on purpose: the storage schema and matching policy
/// are ours, so we don't couple them to — or leak — FluidAudio's `Speaker` past
/// the diarization adapter boundary (CLAUDE.md "keep engines swappable"). The
/// embedding is expected L2-normalized, as `SpeakerManager` produces it.
public struct Voiceprint: Sendable, Equatable, Hashable, Codable, Identifiable {
    /// Stable identity across sessions and app launches.
    public let id: UUID

    /// Display name shown in the transcript (e.g. "Eric").
    public var name: String

    /// 256-dim L2-normalized speaker embedding (``SpeakerManager`` dimension).
    public let embedding: [Float]

    public init(id: UUID = UUID(), name: String, embedding: [Float]) {
        self.id = id
        self.name = name
        self.embedding = embedding
    }
}
