import Foundation
import Testing
@testable import SayWhatCore

@Suite("TranscriptMerger")
struct TranscriptMergerTests {
    /// A finalized segment on one track over `start..<end` seconds.
    private func segment(
        _ source: CaptureSource,
        _ text: String,
        from start: Double,
        to end: Double,
        isFinal: Bool = true
    ) -> TranscriptSegment {
        TranscriptSegment(
            source: source,
            text: text,
            range: .seconds(start) ..< .seconds(end),
            isFinal: isFinal
        )
    }

    @Test("interleaves mic and system turns in timeline order")
    func interleavesByTime() {
        let mic = [
            segment(.microphone, "hello", from: 0, to: 1),
            segment(.microphone, "bye", from: 4, to: 5),
        ]
        let system = [segment(.system, "hi there", from: 1, to: 3)]
        let result = TranscriptMerger().merge(
            mic: mic,
            system: system,
            remoteSpeakers: SpeakerTimeline()
        )

        #expect(result.utterances.map(\.text) == ["hello", "hi there", "bye"])
        #expect(result.utterances.map(\.speaker) == [.you, .remote(0), .you])
        #expect(result.utterances.map(\.id) == [0, 1, 2])
    }

    @Test("names each system turn by the dominant offline speaker")
    func namesRemoteSpeakers() {
        let system = [
            segment(.system, "first", from: 0, to: 1),
            segment(.system, "second", from: 2, to: 3),
        ]
        let timeline = SpeakerTimeline(turns: [
            SpeakerTurn(speaker: 0, range: .seconds(0) ..< .seconds(1)),
            SpeakerTurn(speaker: 1, range: .seconds(2) ..< .seconds(3)),
        ])
        let result = TranscriptMerger().merge(mic: [], system: system, remoteSpeakers: timeline)

        #expect(result.utterances.map(\.speaker) == [.remote(0), .remote(1)])
    }

    @Test("tags each remote slot with its resolved persistent identity")
    func appliesResolvedNames() {
        let system = [
            segment(.system, "first", from: 0, to: 1),
            segment(.system, "second", from: 2, to: 3),
        ]
        let timeline = SpeakerTimeline(turns: [
            SpeakerTurn(speaker: 0, range: .seconds(0) ..< .seconds(1)),
            SpeakerTurn(speaker: 1, range: .seconds(2) ..< .seconds(3)),
        ])
        let result = TranscriptMerger().merge(
            mic: [],
            system: system,
            remoteSpeakers: timeline,
            names: [0: "Eric", 1: "Ashley"]
        )

        #expect(result.utterances.map(\.speakerName) == ["Eric", "Ashley"])
    }

    @Test("a slot with no resolved name keeps a nil identity; you is never named")
    func unnamedSlotsAndYou() {
        let mic = [segment(.microphone, "me", from: 0, to: 1)]
        let system = [segment(.system, "them", from: 1, to: 2)]
        let timeline = SpeakerTimeline(turns: [
            SpeakerTurn(speaker: 0, range: .seconds(1) ..< .seconds(2)),
        ])
        // Only slot 1 is named; slot 0 (the actual speaker here) isn't.
        let result = TranscriptMerger().merge(
            mic: mic,
            system: system,
            remoteSpeakers: timeline,
            names: [1: "Ashley"]
        )

        #expect(result.utterances.map(\.speakerName) == [nil, nil])
    }

    @Test("a coalesced same-speaker block keeps the first turn's resolved name")
    func coalesceKeepsName() {
        let system = [
            segment(.system, "one", from: 0, to: 1),
            segment(.system, "two", from: 1, to: 2),
        ]
        let timeline = SpeakerTimeline(turns: [
            SpeakerTurn(speaker: 0, range: .seconds(0) ..< .seconds(2)),
        ])
        let result = TranscriptMerger().merge(
            mic: [],
            system: system,
            remoteSpeakers: timeline,
            names: [0: "Eric"]
        )

        #expect(result.utterances.count == 1)
        #expect(result.utterances.first?.text == "one two")
        #expect(result.utterances.first?.speakerName == "Eric")
    }

    @Test("coalesces consecutive same-speaker turns into one block")
    func coalescesSameSpeaker() {
        let mic = [
            segment(.microphone, "one", from: 0, to: 1),
            segment(.microphone, "two", from: 1, to: 2),
        ]
        let result = TranscriptMerger().merge(
            mic: mic,
            system: [],
            remoteSpeakers: SpeakerTimeline()
        )

        #expect(result.utterances.count == 1)
        #expect(result.utterances.first?.text == "one two")
        #expect(result.utterances.first?.range == .seconds(0) ..< .seconds(2))
    }

    @Test("drops volatile and empty segments")
    func dropsVolatileAndEmpty() {
        let mic = [
            segment(.microphone, "kept", from: 0, to: 1),
            segment(.microphone, "volatile", from: 1, to: 2, isFinal: false),
            segment(.microphone, "   ", from: 2, to: 3),
        ]
        let result = TranscriptMerger().merge(
            mic: mic,
            system: [],
            remoteSpeakers: SpeakerTimeline()
        )

        #expect(result.utterances.map(\.text) == ["kept"])
    }

    @Test("remote turn with no diarized coverage falls back to slot 0")
    func remoteFallback() {
        let system = [segment(.system, "who am i", from: 5, to: 6)]
        let result = TranscriptMerger().merge(
            mic: [],
            system: system,
            remoteSpeakers: SpeakerTimeline()
        )

        #expect(result.utterances.first?.speaker == .remote(0))
    }

    @Test("an empty merge yields an empty transcript")
    func empty() {
        let result = TranscriptMerger().merge(
            mic: [],
            system: [],
            remoteSpeakers: SpeakerTimeline()
        )
        #expect(result.isEmpty)
        #expect(result.duration == .zero)
    }

    @Test("duration is the end of the last utterance")
    func duration() {
        let mic = [segment(.microphone, "done", from: 0, to: 7)]
        let result = TranscriptMerger().merge(
            mic: mic,
            system: [],
            remoteSpeakers: SpeakerTimeline()
        )
        #expect(result.duration == .seconds(7))
    }
}
