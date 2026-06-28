import Foundation
import Testing
@testable import SayWhatCore

@Suite("SpeakerTimeline")
struct SpeakerTimelineTests {
    @Test("picks the speaker covering most of the window")
    func dominant() {
        let timeline = SpeakerTimeline(turns: [
            SpeakerTurn(speaker: 0, range: .seconds(0) ..< .seconds(2)),
            SpeakerTurn(speaker: 1, range: .seconds(2) ..< .seconds(5)),
        ])
        // 1...4 overlaps speaker 0 by 1 s and speaker 1 by 2 s → 1.
        #expect(timeline.dominantSpeaker(in: .seconds(1) ..< .seconds(4)) == 1)
    }

    @Test("sums coverage across a speaker's multiple turns")
    func sumsCoverage() {
        let timeline = SpeakerTimeline(turns: [
            SpeakerTurn(speaker: 0, range: .seconds(0) ..< .seconds(1)),
            SpeakerTurn(speaker: 0, range: .seconds(3) ..< .seconds(4)),
            SpeakerTurn(speaker: 1, range: .seconds(1) ..< .seconds(2.5)),
        ])
        // 0...4: speaker 0 = 1 + 1 = 2 s, speaker 1 = 1.5 s → 0.
        #expect(timeline.dominantSpeaker(in: .seconds(0) ..< .seconds(4)) == 0)
    }

    @Test("returns nil when no turn overlaps the window")
    func noOverlap() {
        let timeline = SpeakerTimeline(turns: [
            SpeakerTurn(speaker: 0, range: .seconds(0) ..< .seconds(1)),
        ])
        #expect(timeline.dominantSpeaker(in: .seconds(5) ..< .seconds(6)) == nil)
    }

    @Test("an empty timeline has no dominant speaker")
    func empty() {
        #expect(SpeakerTimeline().dominantSpeaker(in: .seconds(0) ..< .seconds(1)) == nil)
    }

    @Test("the nearest speaker is the turn with the smallest time gap")
    func nearest() {
        let timeline = SpeakerTimeline(turns: [
            SpeakerTurn(speaker: 0, range: .seconds(0) ..< .seconds(2)),
            SpeakerTurn(speaker: 1, range: .seconds(10) ..< .seconds(12)),
        ])
        // A word at 9...9.3 sits in the gap; turn 1 (gap 0.7s) beats turn 0 (gap 7s).
        #expect(timeline.nearestSpeaker(to: .seconds(9) ..< .seconds(9.3)) == 1)
        // Right after turn 0 ends, turn 0 is nearer.
        #expect(timeline.nearestSpeaker(to: .seconds(3) ..< .seconds(3.2)) == 0)
    }

    @Test("nearest speaker prefers the earlier turn on a tie")
    func nearestTieByStart() {
        let timeline = SpeakerTimeline(turns: [
            SpeakerTurn(speaker: 7, range: .seconds(0) ..< .seconds(2)),
            SpeakerTurn(speaker: 3, range: .seconds(6) ..< .seconds(8)),
        ])
        // A word at 3...5 is 1s from both turns; the earlier-starting turn wins.
        #expect(timeline.nearestSpeaker(to: .seconds(3) ..< .seconds(5)) == 7)
    }

    @Test("an empty timeline has no nearest speaker")
    func nearestEmpty() {
        #expect(SpeakerTimeline().nearestSpeaker(to: .seconds(0) ..< .seconds(1)) == nil)
    }
}
