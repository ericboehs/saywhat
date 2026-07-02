import Foundation

/// Picks the calendar event a recording belongs to. Pure policy over
/// ``MeetingEvent`` values, so the rules are unit-testable without a calendar.
public enum MeetingMatcher {
    /// The event a recording started at `date` most plausibly captures, or `nil`
    /// when none fits.
    ///
    /// - An **in-progress** event (started, not yet ended) wins outright. When
    ///   several overlap, one with an invite roster beats a solitary block (a
    ///   real meeting over a "Focus time" placeholder), then the latest start
    ///   wins (the most recently begun is the one being recorded).
    /// - Otherwise the **next upcoming** event starting within `tolerance` wins
    ///   — recording often starts a few minutes before the hour.
    /// - An event that already ended is never matched: a recording can't capture
    ///   a meeting that's over.
    public static func match(
        events: [MeetingEvent],
        at date: Date,
        tolerance: TimeInterval = 15 * 60
    ) -> MeetingEvent? {
        let inProgress = events.filter { $0.start <= date && date < $0.end }
        if !inProgress.isEmpty {
            return inProgress.min { lhs, rhs in
                if lhs.attendees.isEmpty != rhs.attendees.isEmpty {
                    return !lhs.attendees.isEmpty
                }
                return lhs.start > rhs.start
            }
        }
        return events
            .filter { $0.start > date && $0.start.timeIntervalSince(date) <= tolerance }
            .min { $0.start < $1.start }
    }
}
