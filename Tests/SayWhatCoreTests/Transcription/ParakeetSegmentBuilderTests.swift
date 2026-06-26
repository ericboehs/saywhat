import Foundation
import Testing
@testable import SayWhatCore

@Suite("ParakeetSegmentBuilder")
struct ParakeetSegmentBuilderTests {
    /// A SentencePiece token spanning `start..<end` seconds.
    private func token(_ text: String, from start: Double, to end: Double) -> TimedToken {
        TimedToken(text: text, start: .seconds(start), end: .seconds(end))
    }

    private let builder = ParakeetSegmentBuilder(source: .system)

    @Test("reconstructs words from SentencePiece tokens into one segment")
    func detokenizesOneUtterance() {
        let tokens = [
            token("\u{2581}hello", from: 0.0, to: 0.3),
            token("\u{2581}there", from: 0.3, to: 0.6),
            token("!", from: 0.6, to: 0.7),
        ]
        let result = builder.segments(tokens: tokens)

        #expect(result.count == 1)
        #expect(result[0].text == "hello there!")
        #expect(result[0].source == .system)
        #expect(result[0].isFinal)
        #expect(result[0].range == .seconds(0.0) ..< .seconds(0.7))
    }

    @Test("splits into separate utterances on a speech pause")
    func splitsOnPause() {
        let tokens = [
            token("\u{2581}one", from: 0.0, to: 0.3),
            token("\u{2581}two", from: 0.4, to: 0.7),
            // 0.8 s gap (> 0.6 s default) starts a new utterance.
            token("\u{2581}three", from: 1.5, to: 1.8),
        ]
        let result = builder.segments(tokens: tokens)

        #expect(result.map(\.text) == ["one two", "three"])
        #expect(result[0].range == .seconds(0.0) ..< .seconds(0.7))
        #expect(result[1].range == .seconds(1.5) ..< .seconds(1.8))
    }

    @Test("offsets every segment by the track's session base")
    func appliesBaseOffset() {
        let tokens = [token("\u{2581}late", from: 0.0, to: 0.5)]
        let result = builder.segments(tokens: tokens, base: .seconds(10))

        #expect(result[0].range == .seconds(10.0) ..< .seconds(10.5))
    }

    @Test("a custom pause threshold changes where utterances break")
    func customPause() {
        let tight = ParakeetSegmentBuilder(source: .system, utterancePause: .milliseconds(100))
        let tokens = [
            token("\u{2581}a", from: 0.0, to: 0.3),
            token("\u{2581}b", from: 0.5, to: 0.8), // 0.2 s gap > 0.1 s → split
        ]
        #expect(tight.segments(tokens: tokens).map(\.text) == ["a", "b"])
    }

    @Test("falls back to a single segment when the model gives no timings")
    func fallbackWithoutTimings() {
        let result = builder.segments(
            tokens: [],
            fallbackText: "  whole thing  ",
            fallbackDuration: .seconds(4),
            base: .seconds(2)
        )

        #expect(result.count == 1)
        #expect(result[0].text == "whole thing")
        #expect(result[0].range == .seconds(2.0) ..< .seconds(6.0))
    }

    @Test("yields nothing for no tokens and no fallback text")
    func emptyYieldsNothing() {
        #expect(builder.segments(tokens: []).isEmpty)
        #expect(builder.segments(tokens: [], fallbackText: "   ").isEmpty)
    }

    @Test("drops a group that detokenizes to whitespace only")
    func dropsBlankGroup() {
        let tokens = [token("\u{2581}", from: 0.0, to: 0.2)]
        #expect(builder.segments(tokens: tokens).isEmpty)
    }
}
