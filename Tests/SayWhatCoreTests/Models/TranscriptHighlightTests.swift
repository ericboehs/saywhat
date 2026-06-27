import Foundation
import Testing
@testable import SayWhatCore

@Suite("Transcript.wordCursor")
struct TranscriptHighlightTests {
    /// A word spanning `start..<end` seconds.
    private func word(_ text: String, from start: Double, to end: Double) -> WordTiming {
        WordTiming(text: text, range: .seconds(start) ..< .seconds(end))
    }

    /// A two-utterance transcript with word timings: "hello world" (you, 0–1) then
    /// "hi there" (a remote speaker, 2–3.2).
    private func sample() -> Transcript {
        Transcript(utterances: [
            Transcript.Utterance(
                id: 0,
                speaker: .you,
                text: "hello world",
                range: .seconds(0) ..< .seconds(1),
                words: [word("hello", from: 0.2, to: 0.4), word("world", from: 0.5, to: 1.0)]
            ),
            Transcript.Utterance(
                id: 1,
                speaker: .remote(0),
                text: "hi there",
                range: .seconds(2) ..< .seconds(3.2),
                words: [word("hi", from: 2.0, to: 2.3), word("there", from: 2.6, to: 3.2)]
            ),
        ])
    }

    @Test("before the first word starts, nothing is highlighted")
    func beforeStart() {
        // First word "hello" starts at 0.2 s, so the lead-in is unhighlighted.
        #expect(sample().wordCursor(at: .milliseconds(100)) == nil)
    }

    @Test("at and within a word's span, that word is the cursor")
    func withinWord() {
        #expect(sample().wordCursor(at: .milliseconds(200)) == .init(utteranceID: 0, wordIndex: 0))
        #expect(sample().wordCursor(at: .milliseconds(700)) == .init(utteranceID: 0, wordIndex: 1))
    }

    @Test("in the gap after a word, the previous word stays lit until the next begins")
    func holdsThroughGap() {
        // 1.5 s is past "world" (ends 1.0) but before "hi" (starts 2.0).
        #expect(sample().wordCursor(at: .seconds(1.5)) == .init(utteranceID: 0, wordIndex: 1))
    }

    @Test("the cursor crosses into the next utterance's words")
    func acrossUtterances() {
        #expect(sample().wordCursor(at: .seconds(2.1)) == .init(utteranceID: 1, wordIndex: 0))
        #expect(sample().wordCursor(at: .seconds(3.0)) == .init(utteranceID: 1, wordIndex: 1))
    }

    @Test("a transcript without word timings never yields a cursor")
    func noTimings() {
        let transcript = Transcript(utterances: [
            Transcript.Utterance(
                id: 0,
                speaker: .you,
                text: "untimed",
                range: .seconds(0) ..< .seconds(1)
            ),
        ])
        #expect(transcript.wordCursor(at: .milliseconds(500)) == nil)
    }
}
