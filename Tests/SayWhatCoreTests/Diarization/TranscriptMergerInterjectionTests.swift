import Foundation
import Testing
@testable import SayWhatCore

/// Chronological interjection ordering: a short reaction from one track lands at
/// the moment it was spoken, splitting the other speaker's turn in place — even
/// when that speaker never paused (a monologue read off a script). The merge
/// orders atoms by time and re-coalesces each speaker's consecutive runs, so the
/// split is driven by *when* the interjection happened, not by a handoff pause.
@Suite("TranscriptMerger interjection ordering")
struct TranscriptMergerInterjectionTests {
    private func word(_ text: String, _ start: Double, _ end: Double) -> WordTiming {
        WordTiming(text: text, range: .seconds(start) ..< .seconds(end))
    }

    private func worded(_ source: CaptureSource, _ words: [WordTiming]) -> TranscriptSegment {
        let lower = words.first?.range.lowerBound ?? .zero
        let upper = words.last?.range.upperBound ?? .zero
        return TranscriptSegment(
            source: source,
            text: words.map(\.text).joined(separator: " "),
            range: lower ..< upper,
            isFinal: true,
            words: words
        )
    }

    @Test("a backchannel splits a continuous monologue at the moment it's spoken")
    func backchannelSplitsContinuousMonologue() {
        // The remote reads a script with no pause long enough to hand off the
        // floor; the user drops a quick "oh" partway through. The old turn-keeping
        // order piled the whole monologue first and the reaction after it (the
        // screenshot bug). Chronological order splits the monologue in place.
        let remote = worded(.system, [
            word("the", 0.0, 0.4), word("way", 0.5, 0.9),
            word("things", 1.0, 1.4),
            // no >0.8s gap anywhere — this is one unbroken turn
            word("work", 2.0, 2.4), word("today", 2.5, 2.9),
        ])
        let mic = worded(.microphone, [word("oh", 1.5, 1.8)])
        let result = TranscriptMerger().merge(
            mic: [mic],
            system: [remote],
            remoteSpeakers: SpeakerTimeline()
        )

        #expect(result.utterances.map(\.speaker) == [.remote(0), .you, .remote(0)])
        #expect(result.utterances.map(\.text) == ["the way things", "oh", "work today"])
    }

    @Test("a mic interjection in a real pause splits the remote turn in place")
    func interjectionSplitsTurnAtPause() {
        // The remote speaks, pauses, then resumes; the user drops a word into that
        // pause. It lands between the two remote halves, ordered purely by time.
        let remote = worded(.system, [
            word("the", 0.0, 0.4), word("point", 0.4, 0.8),
            word("is", 0.8, 1.2), word("proven", 1.2, 2.0),
            word("but", 3.0, 3.4), word("yeah", 3.4, 4.0),
        ])
        let mic = worded(.microphone, [word("right", 2.3, 2.7)])
        let result = TranscriptMerger().merge(
            mic: [mic],
            system: [remote],
            remoteSpeakers: SpeakerTimeline()
        )

        #expect(result.utterances.map(\.speaker) == [.remote(0), .you, .remote(0)])
        #expect(result.utterances.map(\.text) == ["the point is proven", "right", "but yeah"])
    }

    @Test("several reactions interleave a long monologue in spoken order")
    func multipleReactionsStayChronological() {
        // Two quick reactions during one monologue must appear at their own times,
        // not collected together after the whole turn (the regression we hit).
        // They arrive as separate segments (the ASR splits on the pause between
        // them), each landing at its own moment.
        let remote = worded(.system, [
            word("a", 0.0, 0.4), word("b", 0.5, 0.9),
            word("c", 1.5, 1.9), word("d", 2.5, 2.9),
        ])
        let oh = worded(.microphone, [word("oh", 1.0, 1.3)])
        let okay = worded(.microphone, [word("okay", 2.0, 2.3)])
        let result = TranscriptMerger().merge(
            mic: [oh, okay],
            system: [remote],
            remoteSpeakers: SpeakerTimeline()
        )

        #expect(result.utterances.map(\.speaker) == [
            .remote(0),
            .you,
            .remote(0),
            .you,
            .remote(0),
        ])
        #expect(result.utterances.map(\.text) == ["a b", "oh", "c", "okay", "d"])
    }

    @Test("a long mic reaction over a remote turn stays whole, never shredded")
    func longOverlappingReactionStaysWhole() {
        // The user talks *over* the remote for a few seconds — both turns genuinely
        // overlap in time. Exploding both tracks to words would interleave them into
        // a one-word-per-line salad (the screenshot bug). The mic is the interjector
        // here: its whole turn lands at its start and splits the remote run once,
        // and the remote words it overlapped re-coalesce around it.
        let remote = worded(.system, [
            word("the", 0.0, 0.4), word("problem", 0.5, 0.9),
            word("is", 1.0, 1.4), word("really", 1.5, 1.9),
            word("hard", 2.5, 2.9), word("to", 3.0, 3.4),
            word("solve", 3.5, 3.9), word("for", 4.0, 4.4),
        ])
        let mic = worded(.microphone, [
            word("yeah", 2.0, 2.3), word("that", 2.3, 2.6),
            word("makes", 2.6, 2.9), word("sense", 2.9, 3.2),
        ])
        let result = TranscriptMerger().merge(
            mic: [mic],
            system: [remote],
            remoteSpeakers: SpeakerTimeline()
        )

        #expect(result.utterances.map(\.speaker) == [.remote(0), .you, .remote(0)])
        #expect(result.utterances.map(\.text) == [
            "the problem is really",
            "yeah that makes sense",
            "hard to solve for",
        ])
    }
}
