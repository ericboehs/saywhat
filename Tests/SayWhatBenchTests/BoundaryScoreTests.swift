import SayWhatCore
import Testing
@testable import SayWhatBench

@Suite("BoundaryScore")
struct BoundaryScoreTests {
    private static func transcript(_ ranges: [(Double, Double)]) -> Transcript {
        Transcript(utterances: ranges.enumerated().map { index, range in
            Transcript.Utterance(
                id: index,
                speaker: .remote(0),
                text: "x",
                range: .seconds(range.0) ..< .seconds(range.1)
            )
        })
    }

    @Test("identical boundaries are all within tolerance with zero error")
    func perfect() {
        let truth = Self.transcript([(0, 5), (5, 10)])
        let score = BoundaryScore(hypothesis: truth, reference: truth)
        #expect(score.withinTolerance == 1)
        #expect(score.meanAbsoluteError == 0)
    }

    @Test("a boundary just past the tolerance misses, one within hits")
    func tolerance() {
        let reference = Self.transcript([(0, 10)])
        // start off by 300ms (hit), end off by 800ms (miss) at ±500ms.
        let hypothesis = Self.transcript([(0.3, 10.8)])
        let score = BoundaryScore(hypothesis: hypothesis, reference: reference, tolerance: 0.5)
        #expect(score.withinTolerance == 0.5) // 1 of 2 boundaries
        #expect(abs(score.meanAbsoluteError - 0.55) < 1e-9) // (0.3 + 0.8) / 2
    }

    @Test("a reference utterance with no overlapping hypothesis counts as two misses")
    func noOverlap() {
        let reference = Self.transcript([(0, 5), (100, 105)])
        let hypothesis = Self.transcript([(0, 5)]) // nothing near the second turn
        let score = BoundaryScore(hypothesis: hypothesis, reference: reference)
        // 2 of 4 reference boundaries matched (the first utterance), 2 missed.
        #expect(score.withinTolerance == 0.5)
    }

    @Test("an empty reference has no boundaries to match, so scores zero")
    func emptyReference() {
        let score = BoundaryScore(hypothesis: Self.transcript([(0, 5)]), reference: Transcript())
        #expect(score.withinTolerance == 0)
        #expect(score.meanAbsoluteError == 0)
    }
}
