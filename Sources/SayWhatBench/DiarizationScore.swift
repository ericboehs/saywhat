import Foundation
import SayWhatCore

/// How well a hypothesis split the audio into *who spoke when*, scored two ways.
///
/// - ``der`` (Diarization Error Rate) is the time-weighted standard: the fraction of
///   reference speech time the hypothesis mislabels, after the hypothesis's speaker
///   ids are optimally mapped onto the reference's (the cluster *ids* are arbitrary —
///   only the grouping is judged). It folds in confusion (wrong speaker), missed
///   speech, and false alarms.
/// - ``clusterConsistency`` is earl-scribe's coarser, more legible check: of the
///   reference utterances, what fraction land in the hypothesis cluster that
///   dominates their reference speaker. A run that puts all of one person's turns in
///   one cluster scores 1.0 even if the boundaries wobble.
///
/// Both ignore the *names* a pipeline assigns — identity resolution is a separate
/// concern. Speakers are compared purely as clusters keyed off ``label(for:)``.
public struct DiarizationScore: Sendable, Equatable {
    /// Diarization Error Rate in `0...1` (lower is better): mislabeled reference time
    /// over total reference speech time.
    public let der: Double
    /// Fraction of reference utterances whose hypothesis speaker matches the mapping
    /// (1.0 = every turn clustered with the right person).
    public let clusterConsistency: Double

    /// One speaker-attributed span on the session timeline.
    struct Segment {
        let start: Double
        let end: Double
        let label: String
    }

    /// Score `hypothesis` against `reference`. The label of a turn is its resolved
    /// name when present, else its channel/slot — so a named hypothesis and a named
    /// reference compare on names, while raw `Speaker N` clusters compare structurally.
    public init(hypothesis: Transcript, reference: Transcript) {
        let hyp = Self.segments(of: hypothesis)
        let ref = Self.segments(of: reference)
        let mapping = Self.optimalMapping(hypothesis: hyp, reference: ref)
        der = Self.errorRate(hypothesis: hyp, reference: ref, mapping: mapping)
        clusterConsistency = Self.consistency(
            hypothesis: hyp,
            reference: reference,
            mapping: mapping
        )
    }

    /// The cluster key for an utterance: its resolved name, else `you`/`remote:N`.
    static func label(for utterance: Transcript.Utterance) -> String {
        if let name = utterance.speakerName { return name }
        switch utterance.speaker {
        case .you: return "you"
        case let .remote(slot): return "remote:\(slot)"
        }
    }

    private static func segments(of transcript: Transcript) -> [Segment] {
        transcript.utterances.map {
            Segment(start: seconds($0.start), end: seconds($0.end), label: label(for: $0))
        }
    }

    /// Greedily map each hypothesis label to the reference label it shares the most
    /// time with. Greedy (not Hungarian) is exact for the disjoint-label common case
    /// and a sound approximation otherwise; diarization here rarely exceeds a handful
    /// of speakers, where the two agree.
    private static func optimalMapping(
        hypothesis: [Segment],
        reference: [Segment]
    ) -> [String: String] {
        var overlap: [String: [String: Double]] = [:]
        for hyp in hypothesis {
            for ref in reference {
                let shared = overlapSeconds(hyp.start, hyp.end, ref.start, ref.end)
                guard shared > 0 else { continue }
                overlap[hyp.label, default: [:]][ref.label, default: 0] += shared
            }
        }
        return overlap.mapValues { byRef in
            byRef.max { $0.value < $1.value }?.key ?? ""
        }
    }

    /// Time-weighted DER: walk a sweep over every boundary, and for each slice charge
    /// an error when the mapped hypothesis speaker disagrees with the reference (or
    /// either side is silent while the other speaks).
    private static func errorRate(
        hypothesis: [Segment],
        reference: [Segment],
        mapping: [String: String]
    ) -> Double {
        let bounds = (hypothesis + reference)
            .flatMap { [$0.start, $0.end] }
            .sorted()
        guard bounds.count > 1 else { return 0 }

        var referenceTime = 0.0
        var errorTime = 0.0
        for index in 0 ..< bounds.count - 1 {
            let lower = bounds[index]
            let upper = bounds[index + 1]
            let span = upper - lower
            guard span > 0 else { continue }
            let mid = (lower + upper) / 2
            let refLabel = label(at: mid, in: reference)
            let hypLabel = label(at: mid, in: hypothesis).map { mapping[$0] ?? $0 }
            if refLabel != nil { referenceTime += span }
            if refLabel != hypLabel { errorTime += span }
        }
        return referenceTime > 0 ? min(1, errorTime / referenceTime) : 0
    }

    private static func consistency(
        hypothesis: [Segment],
        reference: Transcript,
        mapping: [String: String]
    ) -> Double {
        guard !reference.utterances.isEmpty else { return 1 }
        var correct = 0
        for utterance in reference.utterances {
            let mid = (seconds(utterance.start) + seconds(utterance.end)) / 2
            let hypLabel = label(at: mid, in: hypothesis).map { mapping[$0] ?? $0 }
            if hypLabel == label(for: utterance) { correct += 1 }
        }
        return Double(correct) / Double(reference.utterances.count)
    }

    /// The label of the segment covering `time`, or `nil` in a gap (silence).
    private static func label(at time: Double, in segments: [Segment]) -> String? {
        segments.first { $0.start <= time && time < $0.end }?.label
    }

    private static func overlapSeconds(
        _ aStart: Double,
        _ aEnd: Double,
        _ bStart: Double,
        _ bEnd: Double
    ) -> Double {
        max(0, min(aEnd, bEnd) - max(aStart, bStart))
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
