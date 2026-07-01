import Foundation
import SayWhatCore

/// One pipeline's score against a ground-truth reference: the three quality axes
/// SayWhat cares about — transcript, speakers, segmentation — bundled so an on-device
/// run and a cloud reference (e.g. Deepgram Nova 3) can be lined up side by side.
///
/// This is the unit the `saywhat bench` command prints and the format a future CI
/// regression check would diff. It holds only the scores, not the transcripts —
/// computing it consumes two ``Transcript`` values (a hypothesis and a reference),
/// however each was produced (the on-device final pass, a JSONL fixture, a cloud API).
public struct BenchmarkReport: Sendable, Equatable {
    /// A human label for the system under test, e.g. `"on-device"` or `"deepgram-nova-3"`.
    public let system: String
    public let wordErrorRate: WordErrorRate
    public let diarization: DiarizationScore
    public let boundary: BoundaryScore

    public init(system: String, hypothesis: Transcript, reference: Transcript) {
        self.system = system
        wordErrorRate = WordErrorRate(hypothesis: hypothesis, reference: reference)
        diarization = DiarizationScore(hypothesis: hypothesis, reference: reference)
        boundary = BoundaryScore(hypothesis: hypothesis, reference: reference)
    }

    /// A compact one-block summary for the terminal. Percentages where a percentage
    /// reads naturally; raw counts for the WER error breakdown.
    public func summary() -> String {
        let wer = wordErrorRate
        return """
        \(system)
          WER            \(percent(wer.rate))  (\(wer.substitutions)S \(wer.insertions)I \(wer
            .deletions)D \
        / \(wer.referenceWords) ref words)
          DER            \(percent(diarization.der))
          cluster        \(percent(diarization.clusterConsistency)) consistent
          boundaries     \(percent(boundary.withinTolerance)) within ±\(Int(boundary
                  .tolerance * 1000))ms\
         (mae \(String(format: "%.0f", boundary.meanAbsoluteError * 1000))ms)
        """
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }
}
