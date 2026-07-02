import EventKit
import Foundation

/// The real calendar behind ``CalendarProvider``: a read-only EventKit query
/// against the user's local calendar database — the documented on-device
/// exception (DESIGN.md §6). Nothing is ever written to the calendar, and the
/// lookup never leaves the machine. An adapter (coverage-excluded): the matching
/// and roster policy it feeds is pure and tested in ``MeetingMatcher`` /
/// ``AttendeeRoster``.
public actor EventKitCalendarAdapter: CalendarProvider {
    private let store = EKEventStore()

    public init() {}

    /// Prompt for full (read) access to events, or report the existing grant.
    /// Denial is a normal outcome, not an error — recordings just go untitled.
    public func requestAccess() async -> Bool {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { return true }
        return await (try? store.requestFullAccessToEvents()) ?? false
    }

    /// Timed events within ±4 hours of `date` — wide enough to catch the current
    /// meeting and its neighbors; ``MeetingMatcher`` applies the actual policy.
    /// All-day events are skipped (a birthday isn't a meeting), as is everything
    /// when access hasn't been granted.
    public func events(around date: Date) async -> [MeetingEvent] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let window: TimeInterval = 4 * 60 * 60
        let predicate = store.predicateForEvents(
            withStart: date.addingTimeInterval(-window),
            end: date.addingTimeInterval(window),
            calendars: nil
        )
        return store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .map { event in
                MeetingEvent(
                    title: event.title ?? "Meeting",
                    start: event.startDate,
                    end: event.endDate,
                    attendees: (event.attendees ?? [])
                        .filter { $0.participantType == .person }
                        .map { participant in
                            MeetingAttendee(
                                name: participant.name,
                                email: Self.email(of: participant),
                                isCurrentUser: participant.isCurrentUser
                            )
                        }
                )
            }
    }

    /// The address in a participant's `mailto:` URL, or `nil` for a non-mail
    /// participant (some servers hand back opaque principal URLs).
    private static func email(of participant: EKParticipant) -> String? {
        let url = participant.url
        guard url.scheme?.lowercased() == "mailto" else { return nil }
        let address = String(url.absoluteString.dropFirst("mailto:".count))
        guard !address.isEmpty else { return nil }
        return address.removingPercentEncoding ?? address
    }
}
