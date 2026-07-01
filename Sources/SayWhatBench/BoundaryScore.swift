import Foundation
import SayWhatCore

/// How closely the hypothesis put utterance boundaries where the reference did — the
/// segmentation half of quality, independent of whether the words or speakers are
/// right.
///
/// Each reference utterance is paired with the hypothesis utterance it overlaps most;
/// the absolute start and end deltas are collected, and a boundary counts as a hit
/// when it lands within ``tolerance`` (the earl-scribe convention is ±500 ms). A
/// reference utterance with no overlapping hypothesis contributes two misses — the
/// pipeline simply didn't segment there.
public struct BoundaryScore: Sendable, Equatable {
    /// Fraction of reference boundaries (starts and ends) matched within tolerance.
    public let withinTolerance: Double
    /// Mean absolute boundary error in seconds over the matched pairs (`0` when no
    /// reference utterance found any hypothesis overlap).
    public let meanAbsoluteError: Double
    /// The tolerance a boundary had to fall within to count as a hit, in seconds.
    public let tolerance: Double

    /// Compare segmentation, counting a boundary as correct within `tolerance` seconds.
    public init(hypothesis: Transcript, reference: Transcript, tolerance: Double = 0.5) {
        self.tolerance = tolerance
        let hyp = reference.utterances.isEmpty ? [] : hypothesis.utterances
        var hits = 0
        var errorSum = 0.0
        var errorCount = 0
        let total = max(reference.utterances.count * 2, 1)

        for refUtterance in reference.utterances {
            let refStart = Self.seconds(refUtterance.start)
            let refEnd = Self.seconds(refUtterance.end)
            guard let match = Self.bestOverlap(refStart, refEnd, in: hyp) else { continue }
            let startError = abs(refStart - Self.seconds(match.start))
            let endError = abs(refEnd - Self.seconds(match.end))
            if startError <= tolerance { hits += 1 }
            if endError <= tolerance { hits += 1 }
            errorSum += startError + endError
            errorCount += 2
        }

        withinTolerance = Double(hits) / Double(total)
        meanAbsoluteError = errorCount > 0 ? errorSum / Double(errorCount) : 0
    }

    /// The hypothesis utterance overlapping `[start, end)` the most, or `nil` if none
    /// touch it.
    private static func bestOverlap(
        _ start: Double,
        _ end: Double,
        in utterances: [Transcript.Utterance]
    ) -> Transcript.Utterance? {
        var best: (utterance: Transcript.Utterance, overlap: Double)?
        for utterance in utterances {
            let overlap = max(
                0,
                min(end, seconds(utterance.end)) - max(start, seconds(utterance.start))
            )
            if overlap > (best?.overlap ?? 0) {
                best = (utterance, overlap)
            }
        }
        return best?.utterance
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
