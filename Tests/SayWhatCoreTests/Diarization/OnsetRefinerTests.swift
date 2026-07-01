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

    @Test("leaves a boundary alone when the transition carries no clear pause")
    func keepsRapidTurnTaking() {
        // Back-to-back speakers with only a 0.08s seam — below minSilence, so there's
        // no reliable split point and the diarizer's boundary is trusted as-is.
        let turns = [turn(1, 50.0, 53.22), turn(2, 53.4, 56.0)]
        let words = [
            word("GPT", 52.9, 53.22),
            word("Yeah", 53.3, 53.6),
            word("find", 53.6, 54.0),
        ]
        let refined = OnsetRefiner().refine(turns: turns, words: words)

        #expect(refined == turns)
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
