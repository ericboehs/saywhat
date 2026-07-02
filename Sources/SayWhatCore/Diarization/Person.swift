import Foundation

/// A named speaker — the unit of **cross-session identity**. One person owns one
/// or more ``Voiceprint`` *exemplars* (distinct recordings of their voice); the
/// name lives here, not on each exemplar, because a name is an attribute of the
/// identity, not of any single take (DESIGN.md §6, docs/speaker-identity-exemplars.md).
///
/// Keeping a person's takes as a *set* of exemplars — matched best-first, never
/// averaged together — is what makes recognition robust to the same voice over a
/// phone vs. in a room vs. tired, without blurring two takes into a centroid that
/// matches neither.
public struct Person: Sendable, Equatable, Hashable, Codable, Identifiable {
    /// Stable identity across sessions and app launches.
    public let id: UUID

    /// Display name shown in the transcript (e.g. "Eric").
    public var name: String

    /// The calendar-attendee email this person was named from, when known — the
    /// link that lets a future meeting's invite roster pre-match its attendees
    /// to enrolled voices (DESIGN.md §6). `nil` for people never tied to an
    /// invite; absent in older documents, which decode as `nil`.
    public var email: String?

    public init(id: UUID = UUID(), name: String, email: String? = nil) {
        self.id = id
        self.name = name
        self.email = email
    }
}

/// A ``Person`` together with their enrolled voiceprint exemplars — the unit the
/// matcher scores a slot against (by the person's *best* exemplar). Only persons
/// with at least one exemplar are enrolled; un-named mints are not represented.
public struct EnrolledPerson: Sendable, Equatable {
    public let person: Person
    /// The person's exemplars; non-empty by construction (an enrolled person has
    /// at least one recorded voice).
    public let exemplars: [Voiceprint]

    public init(person: Person, exemplars: [Voiceprint]) {
        self.person = person
        self.exemplars = exemplars
    }
}
