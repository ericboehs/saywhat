import Foundation
import Testing
@testable import SayWhatCore

@Suite("Meeting matcher")
struct MeetingMatcherTests {
    /// A reference "now" so every test's arithmetic reads in minutes from it.
    private let now = Date(timeIntervalSince1970: 1_000_000)

    /// An event `start`…`end` minutes from now, optionally with a roster.
    private func event(
        _ title: String,
        from start: Double,
        to end: Double,
        attendees: Int = 0
    ) -> MeetingEvent {
        MeetingEvent(
            title: title,
            start: now.addingTimeInterval(start * 60),
            end: now.addingTimeInterval(end * 60),
            attendees: (0 ..< attendees).map { MeetingAttendee(name: "Person \($0)") }
        )
    }

    @Test("an in-progress event wins over an upcoming one")
    func inProgressWins() {
        let standup = event("Standup", from: -10, to: 20)
        let planning = event("Planning", from: 5, to: 60)
        #expect(MeetingMatcher.match(events: [planning, standup], at: now) == standup)
    }

    @Test("among overlapping in-progress events, one with an invite roster beats a solo block")
    func rosterBeatsSoloBlock() {
        let focus = event("Focus time", from: -60, to: 60)
        let sync = event("EERT sync", from: -5, to: 25, attendees: 3)
        #expect(MeetingMatcher.match(events: [focus, sync], at: now) == sync)
    }

    @Test("among overlapping in-progress events with rosters, the latest start wins")
    func latestStartWins() {
        let allHands = event("All hands", from: -50, to: 70, attendees: 40)
        let breakout = event("Breakout", from: -5, to: 25, attendees: 4)
        #expect(MeetingMatcher.match(events: [allHands, breakout], at: now) == breakout)
    }

    @Test("with nothing in progress, the next event within tolerance matches")
    func upcomingWithinTolerance() {
        let soon = event("1:1", from: 5, to: 35)
        let later = event("Retro", from: 12, to: 42)
        #expect(MeetingMatcher.match(events: [later, soon], at: now) == soon)
    }

    @Test("an event starting beyond the tolerance does not match")
    func upcomingBeyondToleranceIgnored() {
        let distant = event("Retro", from: 30, to: 60)
        #expect(MeetingMatcher.match(events: [distant], at: now) == nil)
    }

    @Test("an event that already ended never matches")
    func endedEventIgnored() {
        let over = event("Standup", from: -40, to: -10)
        #expect(MeetingMatcher.match(events: [over], at: now) == nil)
    }

    @Test("no events, no match")
    func emptyIsNil() {
        #expect(MeetingMatcher.match(events: [], at: now) == nil)
    }

    @Test("the tolerance is adjustable")
    func customTolerance() {
        let distant = event("Retro", from: 30, to: 60)
        #expect(MeetingMatcher.match(events: [distant], at: now, tolerance: 45 * 60) == distant)
    }
}
