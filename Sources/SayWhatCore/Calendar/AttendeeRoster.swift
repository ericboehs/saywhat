import Foundation

/// Turns a matched event's invite list into remote-speaker name suggestions —
/// the attendee→speaker naming prior (DESIGN.md §6). Pure list policy; the UI
/// just renders what this returns.
public enum AttendeeRoster {
    /// The names to offer when labeling a remote speaker: every attendee except
    /// the machine's user (the mic track already names them), minus names
    /// already assigned to a speaker, deduplicated case-insensitively, in the
    /// invite's order.
    public static func suggestions(
        attendees: [MeetingAttendee],
        excludingAssigned assigned: Set<String> = []
    ) -> [String] {
        let taken = Set(assigned.map { $0.lowercased() })
        var seen: Set<String> = []
        return attendees.compactMap { attendee in
            guard !attendee.isCurrentUser else { return nil }
            let name = attendee.displayName
            let key = name.lowercased()
            guard !name.isEmpty, !taken.contains(key), seen.insert(key).inserted else {
                return nil
            }
            return name
        }
    }

    /// The attendee whose display name matches `name` (case-insensitively) —
    /// how a rename finds the attendee's email to link onto the ``Person``.
    public static func attendee(
        named name: String,
        in attendees: [MeetingAttendee]
    ) -> MeetingAttendee? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        return attendees.first { $0.displayName.lowercased() == key }
    }
}
