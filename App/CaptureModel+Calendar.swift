import Foundation
import SayWhatCore

/// The calendar half of ``CaptureModel``: matching a just-started recording to
/// the event it belongs to (auto-title + attendee roster) and turning that
/// roster into speaker-name suggestions (DESIGN.md §6). Split into an extension
/// so the model's main declaration stays focused on the capture/recording
/// lifecycle.
extension CaptureModel {
    /// Match the just-started recording to the calendar event it belongs to,
    /// titling the session and capturing the attendee roster. Best-effort and
    /// opt-in: a disabled toggle, denied access, or no plausible event just
    /// leaves the session untitled — never an error, never a capture concern.
    func attachMeeting(to session: RecordingSession) async {
        guard UserDefaults.standard.bool(forKey: AppSettings.calendarEnabledKey) else { return }
        let now = Date()
        let events = await calendar.events(around: now)
        guard let matched = MeetingMatcher.match(events: events, at: now) else { return }
        meeting = matched
        // Persist beside the audio so the title and roster survive reopening
        // (the calendar event may have moved or vanished by then).
        try? MeetingStore(directory: session.directory).save(matched)
        // Retitle the sidebar's live entry in place; refreshSessions() would
        // drop it (no audio on disk yet).
        let id = session.directory.lastPathComponent
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            let entry = sessions[index]
            sessions[index] = RecordedSession(
                id: entry.id,
                directory: entry.directory,
                date: entry.date,
                title: matched.title,
                hasTranscript: entry.hasTranscript
            )
        }
    }

    /// Attendee names to offer when labeling a remote speaker: the matched
    /// event's invite roster, minus you and minus names already assigned to a
    /// speaker (DESIGN.md §6 — the roster turns naming from an open-set guess
    /// into picking from a short list). Empty without a calendar match.
    var attendeeSuggestions: [String] {
        guard let meeting else { return [] }
        var assigned = Set(speakers.values.map(\.name))
        if let finalTranscript {
            assigned.formUnion(finalTranscript.utterances.compactMap(\.speakerName))
        }
        return AttendeeRoster.suggestions(
            attendees: meeting.attendees,
            excludingAssigned: assigned
        )
    }
}
