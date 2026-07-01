import Foundation
import SayWhatCore

/// Word Error Rate: the standard transcript-accuracy metric — the minimum number of
/// word substitutions, insertions, and deletions to turn the hypothesis into the
/// reference, divided by the reference word count. Lower is better; `0` is perfect.
///
/// It's a token-level Levenshtein alignment over ``TextNormalization`` tokens, with a
/// backtrace so the three error kinds are reported separately (a recognizer that
/// drops words and one that invents them both raise WER, but you debug them
/// differently). The whole transcript is scored as one concatenated stream, so
/// segmentation differences don't matter here — that's ``BoundaryScore``'s job.
public struct WordErrorRate: Sendable, Equatable {
    /// Words the hypothesis got wrong (right slot, wrong word).
    public let substitutions: Int
    /// Words the hypothesis added that aren't in the reference.
    public let insertions: Int
    /// Reference words the hypothesis missed.
    public let deletions: Int
    /// Total words in the reference — the denominator.
    public let referenceWords: Int

    /// Total aligned errors: substitutions + insertions + deletions.
    public var errors: Int {
        substitutions + insertions + deletions
    }

    /// Errors over reference words. An empty reference scores `0` against an empty
    /// hypothesis and `1` against any non-empty one (every word is spurious).
    public var rate: Double {
        guard referenceWords > 0 else { return errors == 0 ? 0 : 1 }
        return Double(errors) / Double(referenceWords)
    }

    /// Score a hypothesis transcript's full text against a reference's.
    public init(hypothesis: Transcript, reference: Transcript) {
        self.init(hypothesis: Self.text(of: hypothesis), reference: Self.text(of: reference))
    }

    /// Score raw hypothesis text against raw reference text.
    public init(hypothesis: String, reference: String) {
        let hyp = TextNormalization.tokens(hypothesis)
        let ref = TextNormalization.tokens(reference)
        self = Self.align(hypothesis: hyp, reference: ref)
    }

    private init(substitutions: Int, insertions: Int, deletions: Int, referenceWords: Int) {
        self.substitutions = substitutions
        self.insertions = insertions
        self.deletions = deletions
        self.referenceWords = referenceWords
    }

    private static func text(of transcript: Transcript) -> String {
        transcript.utterances.map(\.text).joined(separator: " ")
    }

    /// Levenshtein DP over token arrays, then a backtrace classifying each edit. Rows
    /// index the reference, columns the hypothesis; the diagonal is match/substitute,
    /// up is a deletion (reference word unmatched), left is an insertion (extra
    /// hypothesis word).
    private static func align(hypothesis: [String], reference: [String]) -> WordErrorRate {
        let rows = reference.count
        let cols = hypothesis.count
        var cost = Array(repeating: Array(repeating: 0, count: cols + 1), count: rows + 1)
        for row in 0 ... rows {
            cost[row][0] = row
        }
        for col in 0 ... cols {
            cost[0][col] = col
        }
        for row in 1 ... max(rows, 1) where rows > 0 {
            for col in 1 ... max(cols, 1) where cols > 0 {
                if reference[row - 1] == hypothesis[col - 1] {
                    cost[row][col] = cost[row - 1][col - 1]
                } else {
                    cost[row][col] = 1 + min(
                        cost[row - 1][col - 1],
                        cost[row - 1][col],
                        cost[row][col - 1]
                    )
                }
            }
        }

        var subs = 0, ins = 0, dels = 0
        var row = rows, col = cols
        while row > 0 || col > 0 {
            let diagonalMatch = row > 0 && col > 0 && reference[row - 1] == hypothesis[col - 1]
            if diagonalMatch, cost[row][col] == cost[row - 1][col - 1] {
                row -= 1; col -= 1
            } else if row > 0, col > 0, cost[row][col] == cost[row - 1][col - 1] + 1 {
                subs += 1; row -= 1; col -= 1
            } else if row > 0, cost[row][col] == cost[row - 1][col] + 1 {
                dels += 1; row -= 1
            } else {
                ins += 1; col -= 1
            }
        }
        return WordErrorRate(
            substitutions: subs,
            insertions: ins,
            deletions: dels,
            referenceWords: rows
        )
    }
}
