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

    @Test("drops punctuation-only segments the ASR sometimes emits")
    func dropsPunctuationOnly() {
        let mic = [segment(.microphone, "real words", from: 0, to: 1)]
        // A lone "." on the system track must not become a contentless turn.
        let system = [segment(.system, ".", from: 1, to: 2)]
        let result = TranscriptMerger().merge(
            mic: mic,
            system: system,
            remoteSpeakers: SpeakerTimeline()
        )

        #expect(result.utterances.map(\.text) == ["real words"])
    }

    @Test("strips stray leading punctuation the ASR strands at a segment's start")
    func stripsStrayLeadingPunctuation() {
        // The recognizer sometimes prepends a stranded "." (a trailing mark that
        // floated off the prior utterance); the turn must not open on it.
        let mic = [segment(.microphone, ". All right, I think that would help", from: 0, to: 2)]
        let result = TranscriptMerger().merge(
            mic: mic,
            system: [],
            remoteSpeakers: SpeakerTimeline()
        )

        #expect(result.utterances.map(\.text) == ["All right, I think that would help"])
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

    @Test("threads per-word timings through, concatenating them across a coalesced block")
    func threadsWordTimings() {
        let first = TranscriptSegment(
            source: .microphone,
            text: "hello there",
            range: .seconds(0) ..< .seconds(1),
            isFinal: true,
            words: [
                WordTiming(text: "hello", range: .seconds(0) ..< .milliseconds(500)),
                WordTiming(text: "there", range: .milliseconds(500) ..< .seconds(1)),
            ]
        )
        let second = TranscriptSegment(
            source: .microphone,
            text: "friend",
            range: .seconds(1) ..< .seconds(2),
            isFinal: true,
            words: [WordTiming(text: "friend", range: .seconds(1) ..< .seconds(2))]
        )
        let result = TranscriptMerger().merge(
            mic: [first, second],
            system: [],
            remoteSpeakers: SpeakerTimeline()
        )

        #expect(result.utterances.count == 1)
        #expect(result.utterances.first?.words.map(\.text) == ["hello", "there", "friend"])
        #expect(result.utterances.first?.words.last?.range == .seconds(1) ..< .seconds(2))
    }
}

/// Word-time interleaving and paragraph breaking — the readability rules that
/// keep a long turn from rendering as one wall of mislabeled text.
extension TranscriptMergerTests {
    @Test("an interjection inside a long turn splits it by word time, not wholesale")
    func interjectionSplitsLongTurn() {
        // The remote talks continuously 0–6s (one segment, no internal pauses);
        // you cut in with a single word at 3s. Sorting whole segments would put
        // the whole remote turn first and your word after — instead the word
        // timings interleave, splitting the remote turn around the interjection.
        let remote = TranscriptSegment(
            source: .system,
            text: "so the plan is we ship",
            range: .seconds(0) ..< .seconds(6),
            isFinal: true,
            words: [
                WordTiming(text: "so", range: .seconds(0) ..< .seconds(1)),
                WordTiming(text: "the", range: .seconds(1) ..< .seconds(2)),
                WordTiming(text: "plan", range: .seconds(2) ..< .seconds(3)),
                WordTiming(text: "is", range: .seconds(4) ..< .seconds(5)),
                WordTiming(text: "we", range: .seconds(5) ..< .milliseconds(5500)),
                WordTiming(text: "ship", range: .milliseconds(5500) ..< .seconds(6)),
            ]
        )
        let interjection = TranscriptSegment(
            source: .microphone,
            text: "wait",
            range: .seconds(3) ..< .milliseconds(3500),
            isFinal: true,
            words: [WordTiming(text: "wait", range: .seconds(3) ..< .milliseconds(3500))]
        )
        let result = TranscriptMerger().merge(
            mic: [interjection],
            system: [remote],
            remoteSpeakers: SpeakerTimeline()
        )

        #expect(result.utterances.map(\.speaker) == [.remote(0), .you, .remote(0)])
        #expect(result.utterances.map(\.text) == ["so the plan", "wait", "is we ship"])
    }

    @Test("a real pause breaks one speaker's run into separate timestamped paragraphs")
    func pauseBreaksParagraphs() {
        // Same speaker, but a 3s silence between the two runs (> the 1.5s default).
        let system = [
            segment(.system, "first thought", from: 0, to: 2),
            segment(.system, "second thought", from: 5, to: 7),
        ]
        let result = TranscriptMerger().merge(
            mic: [],
            system: system,
            remoteSpeakers: SpeakerTimeline()
        )

        #expect(result.utterances.map(\.text) == ["first thought", "second thought"])
        #expect(result.utterances.map(\.start) == [.seconds(0), .seconds(5)])
    }

    @Test("a tiny gap keeps one speaker's run in a single paragraph")
    func smallGapKeepsParagraph() {
        // A half-second between turns is below the pause threshold — still one block.
        let system = [
            segment(.system, "one", from: 0, to: 1),
            segment(.system, "two", from: 1.5, to: 2),
        ]
        let result = TranscriptMerger().merge(
            mic: [],
            system: system,
            remoteSpeakers: SpeakerTimeline()
        )

        #expect(result.utterances.map(\.text) == ["one two"])
    }

    @Test("a long monologue breaks at the next sentence boundary, not mid-sentence")
    func longMonologueBreaksAtSentence() {
        // One continuous speaker, no pause over the threshold, but past the 20s
        // soft cap — so it splits where the prior text ended a sentence.
        let system = [
            segment(.system, "this is a long first part.", from: 0, to: 21),
            segment(.system, "and here is the second part", from: 21, to: 30),
        ]
        let result = TranscriptMerger().merge(
            mic: [],
            system: system,
            remoteSpeakers: SpeakerTimeline()
        )

        #expect(result.utterances.map(\.text) == [
            "this is a long first part.",
            "and here is the second part",
        ])
    }
}
