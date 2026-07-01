import SayWhatCore
import Testing
@testable import SayWhatBench

@Suite("WordErrorRate")
struct WordErrorRateTests {
    @Test("an identical transcript scores zero")
    func perfect() {
        let wer = WordErrorRate(hypothesis: "the quick brown fox", reference: "the quick brown fox")
        #expect(wer.rate == 0)
        #expect(wer.errors == 0)
    }

    @Test("counts a substitution, an insertion, and a deletion separately")
    func threeKinds() {
        // ref: a b c d        hyp: a x c d e  (b→x sub, +e ins) ; and a deletion case
        let sub = WordErrorRate(hypothesis: "a x c d", reference: "a b c d")
        #expect((sub.substitutions, sub.insertions, sub.deletions) == (1, 0, 0))

        let ins = WordErrorRate(hypothesis: "a b c d e", reference: "a b c d")
        #expect((ins.substitutions, ins.insertions, ins.deletions) == (0, 1, 0))

        let del = WordErrorRate(hypothesis: "a b d", reference: "a b c d")
        #expect((del.substitutions, del.insertions, del.deletions) == (0, 0, 1))
    }

    @Test("rate is errors over reference word count")
    func rate() {
        let wer = WordErrorRate(hypothesis: "a x c d", reference: "a b c d")
        #expect(wer.referenceWords == 4)
        #expect(abs(wer.rate - 0.25) < 1e-9)
    }

    @Test("normalizes casing and punctuation before comparing")
    func normalizes() {
        let wer = WordErrorRate(hypothesis: "Hello, world!", reference: "hello world")
        #expect(wer.rate == 0)
    }

    @Test("an empty reference scores 0 against empty and 1 against any words")
    func emptyReference() {
        #expect(WordErrorRate(hypothesis: "", reference: "").rate == 0)
        #expect(WordErrorRate(hypothesis: "spurious words", reference: "").rate == 1)
    }

    @Test("an empty hypothesis deletes every reference word")
    func emptyHypothesis() {
        let wer = WordErrorRate(hypothesis: "", reference: "one two three")
        #expect((wer.deletions, wer.rate) == (3, 1))
    }
}
