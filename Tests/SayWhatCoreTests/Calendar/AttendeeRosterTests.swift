import Foundation
import Testing
@testable import SayWhatCore

@Suite("Attendee roster")
struct AttendeeRosterTests {
    @Test("suggests every attendee except the current user, in invite order")
    func excludesCurrentUser() {
        let attendees = [
            MeetingAttendee(name: "Alex Teal"),
            MeetingAttendee(name: "Eric Boehs", isCurrentUser: true),
            MeetingAttendee(name: "Tom Warren"),
        ]
        #expect(AttendeeRoster.suggestions(attendees: attendees) == ["Alex Teal", "Tom Warren"])
    }

    @Test("names already assigned to a speaker are excluded, case-insensitively")
    func excludesAssigned() {
        let attendees = [MeetingAttendee(name: "Alex Teal"), MeetingAttendee(name: "Tom Warren")]
        let remaining = AttendeeRoster.suggestions(
            attendees: attendees,
            excludingAssigned: ["alex teal"]
        )
        #expect(remaining == ["Tom Warren"])
    }

    @Test("duplicate names collapse to one suggestion")
    func deduplicates() {
        let attendees = [
            MeetingAttendee(name: "Alex Teal"),
            MeetingAttendee(name: "alex teal", email: "ateal@example.com"),
        ]
        #expect(AttendeeRoster.suggestions(attendees: attendees) == ["Alex Teal"])
    }

    @Test("a nameless attendee falls back to a readable email local part")
    func emailFallback() {
        let attendees = [
            MeetingAttendee(email: "eric.boehs@oddball.io"),
            MeetingAttendee(name: "  ", email: "tom_warren@example.com"),
            MeetingAttendee(), // neither name nor email — nothing to suggest
        ]
        #expect(AttendeeRoster.suggestions(attendees: attendees) == ["Eric Boehs", "Tom Warren"])
    }

    @Test("attendee(named:) finds the invite entry behind a chosen name")
    func lookupByName() {
        let alex = MeetingAttendee(name: "Alex Teal", email: "alex@example.com")
        let attendees = [alex, MeetingAttendee(name: "Tom Warren")]
        #expect(AttendeeRoster.attendee(named: "alex teal", in: attendees) == alex)
        #expect(AttendeeRoster.attendee(named: " Alex Teal ", in: attendees) == alex)
        #expect(AttendeeRoster.attendee(named: "Nobody", in: attendees) == nil)
        #expect(AttendeeRoster.attendee(named: "  ", in: attendees) == nil)
    }

    @Test("displayName prefers the invite name over the email")
    func displayNamePrefersName() {
        let attendee = MeetingAttendee(name: "Alex Teal", email: "ateal@example.com")
        #expect(attendee.displayName == "Alex Teal")
    }
}
