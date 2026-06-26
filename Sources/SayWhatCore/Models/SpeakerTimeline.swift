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

    public init(turns: [SpeakerTurn] = []) {
        self.turns = turns
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
}

extension Range where Bound == Duration {
    /// Length of this range's overlap with `other`, in seconds (0 if disjoint).
    func overlap(with other: Range<Duration>) -> Double {
        let lower = Swift.max(lowerBound, other.lowerBound)
        let upper = Swift.min(upperBound, other.upperBound)
        guard upper > lower else { return 0 }
        return (upper - lower).seconds
    }
}

extension Duration {
    /// This duration as a `Double` number of seconds.
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
