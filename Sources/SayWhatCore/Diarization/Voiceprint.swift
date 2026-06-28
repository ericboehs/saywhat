import Foundation

/// One enrolled **exemplar** of a speaker's voice: a 256-dim `wespeaker_v2`
/// embedding tied to the ``Person`` it belongs to. A person owns a *set* of these
/// (one per recorded take); matching scores a slot against a person by their best
/// exemplar, never an average, so distinct takes stay distinct (DESIGN.md §6,
/// docs/speaker-identity-exemplars.md).
///
/// This is our own value type on purpose: the storage schema and matching policy
/// are ours, so we don't couple them to — or leak — FluidAudio's `Speaker` past
/// the diarization adapter boundary (CLAUDE.md "keep engines swappable"). The
/// embedding is expected L2-normalized, as `SpeakerManager` produces it.
public struct Voiceprint: Sendable, Equatable, Hashable, Codable, Identifiable {
    /// Stable identity across sessions and app launches.
    public let id: UUID

    /// The enrolled ``Person`` this exemplar belongs to, or `nil` for an un-named
    /// mint — a slot the final pass matched nobody for, held in memory until the
    /// user names it. Un-named exemplars are never cross-session match candidates
    /// (that's what kept the directory from filling with orphan `Speaker N` rows).
    public var personID: UUID?

    /// 256-dim L2-normalized speaker embedding (``SpeakerManager`` dimension).
    public let embedding: [Float]

    public init(id: UUID = UUID(), personID: UUID? = nil, embedding: [Float]) {
        self.id = id
        self.personID = personID
        self.embedding = embedding
    }
}
