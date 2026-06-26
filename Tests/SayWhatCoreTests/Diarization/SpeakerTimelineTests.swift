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
}
