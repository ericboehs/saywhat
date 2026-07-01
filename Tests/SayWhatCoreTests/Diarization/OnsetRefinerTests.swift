import Foundation
import Testing
@testable import SayWhatCore

@Suite("OnsetRefiner")
struct OnsetRefinerTests {
    private func word(_ text: String, _ from: Double, _ to: Double) -> WordTiming {
        WordTiming(text: text, range: .seconds(from) ..< .seconds(to))
    }

    private func turn(_ speaker: Int, _ from: Double, _ to: Double) -> SpeakerTurn {
        SpeakerTurn(speaker: speaker, range: .seconds(from) ..< .seconds(to))
    }

    @Test("snaps a lagging onset back to the silence between the two speakers")
    func snapsLaggingOnset() {
        // Speaker 1's turn tail runs to 49.84 though their last word ends at 48.07;
        // speaker 2's turn doesn't open until 50.88 though they start speaking at
        // 48.9. The real boundary is the 0.83s silence between the words.
        let turns = [turn(1, 46.56, 49.84), turn(2, 50.88, 54.56)]
        let words = [
            word("calendar", 46.6, 48.07),
            word("I", 48.9, 49.1),
            word("think", 49.1, 49.6),
            word("uh", 49.9, 50.26),
            word("is", 50.34, 50.6),
        ]
        let refined = OnsetRefiner().refine(turns: turns, words: words)

        #expect(refined[0].range.upperBound == .seconds(48.07))
        #expect(refined[1].range.lowerBound == .seconds(48.9))
        #expect(refined[0].speaker == 1)
        #expect(refined[1].speaker == 2)
    }

    @Test("leaves a boundary alone when there's no pause and no sentence break")
    func keepsRapidTurnTaking() {
        // Back-to-back speakers with only a 0.08s seam and no sentence-final word to
        // fall back on — no reliable split point, so the diarizer's edge is trusted.
        let turns = [turn(1, 50.0, 53.22), turn(2, 53.4, 56.0)]
        let words = [
            word("GPT", 52.9, 53.22),
            word("Yeah", 53.3, 53.6),
            word("find", 53.6, 54.0),
        ]
        let refined = OnsetRefiner().refine(turns: turns, words: words)

        #expect(refined == turns)
    }

    @Test("falls back to a sentence-final gap when a pause-less turn ends a sentence")
    func snapsToSentenceBoundary() {
        // The lagged diarizer edge sits at 54.98, mid-sentence, but the real seam is
        // the 0.08s gap after "GPT?" — a question, so a speaker change is likely even
        // though the pause (and every other gap here) is far below minSilence. The
        // fallback recovers it where the pause-based primary path finds nothing.
        let turns = [turn(1, 48.9, 54.98), turn(2, 54.98, 61.5)]
        let words = [
            word("GPT?", 52.98, 53.22),
            word("Yeah,", 53.3, 53.9),
            word("gonna", 53.9, 54.2),
            word("say", 54.2, 54.5),
            word("find", 54.5, 54.98),
        ]
        let refined = OnsetRefiner().refine(turns: turns, words: words)

        #expect(refined[0].range.upperBound == .seconds(53.22))
        #expect(refined[1].range.lowerBound == .seconds(53.3))
    }

    @Test("takes the latest sentence-final gap before the edge, not the earliest")
    func picksLatestSentenceGapBeforeEdge() {
        // Two sub-threshold sentence-final gaps precede the lagged edge; the fallback
        // takes the latest (least over-correction), not the earliest.
        let turns = [turn(1, 40.0, 50.0), turn(2, 50.0, 56.0)]
        let words = [
            word("first.", 48.0, 48.3),
            word("mid", 48.5, 48.7),
            word("done.", 48.7, 49.0),
            word("Next", 49.2, 49.8),
        ]
        let refined = OnsetRefiner().refine(turns: turns, words: words)

        #expect(refined[0].range.upperBound == .seconds(49.0))
        #expect(refined[1].range.lowerBound == .seconds(49.2))
    }

    @Test("same-speaker adjacency is never touched")
    func ignoresSameSpeaker() {
        let turns = [turn(1, 0, 3), turn(1, 5, 8)]
        let words = [word("a", 0, 2.9), word("b", 5.1, 8)]
        #expect(OnsetRefiner().refine(turns: turns, words: words) == turns)
    }

    @Test("a single turn or no words is returned unchanged")
    func trivialInputs() {
        let one = [turn(1, 0, 3)]
        #expect(OnsetRefiner().refine(turns: one, words: [word("a", 0, 3)]) == one)
        let two = [turn(1, 0, 3), turn(2, 4, 6)]
        #expect(OnsetRefiner().refine(turns: two, words: []) == two)
    }
}
