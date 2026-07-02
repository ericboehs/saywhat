import Foundation

/// One participant on a calendar event's invite — the raw material for the
/// attendee→speaker naming prior (DESIGN.md §6): a meeting's roster turns naming
/// remote speakers from an open-set guess into picking from a short list.
public struct MeetingAttendee: Sendable, Equatable, Codable {
    /// The invite's display name, when the calendar carries one.
    public var name: String?
    /// The attendee's email address, when the invite carries one. This is what a
    /// rename links back to a ``Person`` so future rosters can pre-match.
    public var email: String?
    /// Whether this attendee is the machine's user. The mic track already names
    /// them (*you*), so they are never offered as a remote-speaker suggestion.
    public var isCurrentUser: Bool

    public init(name: String? = nil, email: String? = nil, isCurrentUser: Bool = false) {
        self.name = name
        self.email = email
        self.isCurrentUser = isCurrentUser
    }

    /// The name to show for this attendee: the invite's display name, or a
    /// readable fallback derived from the email's local part ("eric.boehs@…" →
    /// "Eric Boehs"). Empty only when the invite carried neither.
    public var displayName: String {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        guard let localPart = email?.split(separator: "@").first, !localPart.isEmpty else {
            return ""
        }
        return localPart
            .split(whereSeparator: { ".-_+".contains($0) })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

/// One calendar event a recording can be matched to: its title (the session's
/// auto-title) and its invite roster (the naming prior). A plain value type so
/// the matcher and roster logic stay pure and testable; only the coverage-ignored
/// EventKit adapter touches the real calendar database.
public struct MeetingEvent: Sendable, Equatable, Codable {
    public var title: String
    public var start: Date
    public var end: Date
    public var attendees: [MeetingAttendee]

    public init(title: String, start: Date, end: Date, attendees: [MeetingAttendee] = []) {
        self.title = title
        self.start = start
        self.end = end
        self.attendees = attendees
    }
}
