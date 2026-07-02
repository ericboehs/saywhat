import Foundation

/// Read-only access to the user's calendar — the one documented exception to
/// "no lookups" in the on-device posture (DESIGN.md §6): an optional, local
/// EventKit query that titles a recording and supplies the attendee roster.
/// Behind a protocol like every engine, so the pure matching/roster logic tests
/// against scripted events and only the EventKit adapter touches the system
/// calendar database.
public protocol CalendarProvider: Sendable {
    /// Ask the user for read access to their calendars. Returns whether access
    /// is granted (immediately true when it already was). Never throws — a
    /// denial just leaves recordings untitled.
    func requestAccess() async -> Bool

    /// The calendar events near `date` (implementations pick a window wide
    /// enough to catch the current and adjacent meetings). Empty when access is
    /// denied or the lookup fails — calendar problems must never disturb a
    /// recording.
    func events(around date: Date) async -> [MeetingEvent]
}
