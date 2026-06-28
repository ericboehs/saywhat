import Foundation

/// One speaker's turn on the session timeline, as produced by a ``Diarizer``.
/// ``speaker`` is the engine's own slot/cluster index (e.g. a Sortformer slot
/// 0–3); mapping it to a display name is a UI concern.
public struct SpeakerTurn: Sendable, Equatable {
    /// The diarizer's speaker slot/cluster index for this turn.
    public let speaker: Int

    /// When this turn occurred, relative to the start of the session.
    public let range: Range<Duration>

    public init(speaker: Int, range: Range<Duration>) {
        self.speaker = speaker
        self.range = range
    }
}

/// An evolving who-spoke-when timeline — the running output of a ``Diarizer``.
/// Turns may overlap (cross-talk) and need not be sorted; queries handle both.
public struct SpeakerTimeline: Sendable, Equatable {
    public private(set) var turns: [SpeakerTurn]

    /// Per-slot speaker embedding (256-dim, L2-normalized), when the diarizer
    /// surfaces one — the offline final pass does; the live path leaves it empty.
    /// Keyed by the same slot as ``SpeakerTurn/speaker`` so identity resolution
    /// can match each remote speaker to a persistent ``Voiceprint`` (DESIGN.md §6).
    public let embeddings: [Int: [Float]]

    public init(turns: [SpeakerTurn] = [], embeddings: [Int: [Float]] = [:]) {
        self.turns = turns
        self.embeddings = embeddings
    }

    /// The speaker covering the most of `range`, or `nil` if no turn overlaps it.
    /// Used to attribute a transcript segment to whichever speaker held the floor
    /// across its time window.
    public func dominantSpeaker(in range: Range<Duration>) -> Int? {
        var coverage: [Int: Double] = [:]
        for turn in turns {
            let overlap = range.overlap(with: turn.range)
            if overlap > 0 { coverage[turn.speaker, default: 0] += overlap }
        }
        return coverage.max { $0.value < $1.value }?.key
    }

    /// The speaker of the turn nearest `range` in time, or `nil` only if the
    /// timeline is empty. The right fallback when ``dominantSpeaker(in:)`` finds no
    /// overlap — a word that lands in a *gap* between turns (a brief pause the
    /// diarizer didn't cover) belongs to whoever was speaking around it, not to an
    /// arbitrary fixed slot. With identity re-segmentation, slot 0 is a *named*
    /// person, so a fixed-slot fallback would stamp every gap word with that name.
    public func nearestSpeaker(to range: Range<Duration>) -> Int? {
        turns.min { lhs, rhs in
            let gapLhs = range.gap(to: lhs.range)
            let gapRhs = range.gap(to: rhs.range)
            if gapLhs != gapRhs { return gapLhs < gapRhs }
            return lhs.range.lowerBound < rhs.range.lowerBound
        }?.speaker
    }
}

extension Range where Bound == Duration {
    /// Length of this range's overlap with `other`, in seconds (0 if disjoint).
    func overlap(with other: Range<Duration>) -> Double {
        let lower = Swift.max(lowerBound, other.lowerBound)
        let upper = Swift.min(upperBound, other.upperBound)
        guard upper > lower else { return 0 }
        return (upper - lower).seconds
    }

    /// Seconds of empty space between this range and `other` (0 if they touch or
    /// overlap) — the temporal distance used to find the nearest turn.
    func gap(to other: Range<Duration>) -> Double {
        if upperBound <= other.lowerBound { return (other.lowerBound - upperBound).seconds }
        if other.upperBound <= lowerBound { return (lowerBound - other.upperBound).seconds }
        return 0
    }
}

extension Duration {
    /// This duration as a `Double` number of seconds.
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
