import Foundation

/// Snaps a diarizer's turn boundaries to the transcript's word/silence structure.
///
/// Sortformer (like most diarizers) is sluggish at a speaker *onset*: it holds the
/// outgoing speaker's turn ~1–2s past their last word and doesn't open the incoming
/// speaker's turn until well after they've started, so a quick response gets
/// attributed to whoever just stopped. The ASR, however, times every word — and a
/// real turn change usually sits on a brief silence between words.
///
/// This walks each pair of temporally-adjacent turns from *different* speakers and,
/// within a window around the fuzzy boundary, moves the split to the **largest
/// inter-word silence** — trimming the earlier turn's tail and pulling the later
/// turn's onset back to meet it. When the transition carries no clear pause (rapid
/// turn-taking or genuine overlap) the boundary is left untouched: there's no signal
/// to snap to, and inventing one would be worse than the diarizer's guess.
///
/// Pure and deterministic — turn labels are never changed, only their time bounds,
/// so it composes with ``SpeakerResegmenter`` (which does the opposite: relabels,
/// keeps bounds) and feeds ``TranscriptMerger`` unchanged.
public struct OnsetRefiner: Sendable {
    /// How far on each side of a diarizer boundary to look for a better split — sized
    /// to the diarizer's onset lag, so a word up to this far into the wrong turn can
    /// be recovered.
    private let searchWindow: Duration
    /// The shortest inter-word silence trusted as a real turn boundary. Below this a
    /// gap is just an intra-turn breath, not a speaker change.
    private let minSilence: Duration

    /// - Parameters:
    ///   - searchWindow: half-width of the snap search around each boundary
    ///     (default 2.0s — the observed Sortformer onset lag).
    ///   - minSilence: minimum silence accepted as a turn boundary (default 0.3s).
    public init(
        searchWindow: Duration = .seconds(2.0),
        minSilence: Duration = .seconds(0.3)
    ) {
        self.searchWindow = searchWindow
        self.minSilence = minSilence
    }

    /// Refine `turns` against the ASR's `words`, returning turns with the same
    /// speaker labels but boundaries snapped to nearby silences. `turns` need not be
    /// sorted; the result is ordered by start time.
    public func refine(turns: [SpeakerTurn], words: [WordTiming]) -> [SpeakerTurn] {
        guard turns.count > 1, words.count > 1 else { return turns }
        var result = turns.sorted { $0.range.lowerBound < $1.range.lowerBound }
        let silences = interWordSilences(words)

        for index in 0 ..< (result.count - 1) {
            let earlier = result[index]
            let later = result[index + 1]
            guard earlier.speaker != later.speaker else { continue }

            // The zone in which reassignment is plausible: a window around the fuzzy
            // stretch between the earlier turn's end and the later turn's start.
            let inner = min(earlier.range.upperBound, later.range.lowerBound)
            let outer = max(earlier.range.upperBound, later.range.lowerBound)
            let zone = (inner - searchWindow) ..< (outer + searchWindow)

            guard let split = largestSilence(in: zone, among: silences) else { continue }

            // Trim the earlier turn's tail back to the silence start (when the silence
            // falls inside its run), and pull the later turn's lagging onset back to
            // the silence end (when the silence precedes its start). Guards keep both
            // ranges non-empty and non-overlapping.
            let trimsEarlier = split.lowerBound > earlier.range.lowerBound
                && split.lowerBound < earlier.range.upperBound
            let pullsLater = split.upperBound < later.range.lowerBound
                && split.upperBound < later.range.upperBound
            if trimsEarlier {
                result[index] = SpeakerTurn(
                    speaker: earlier.speaker,
                    range: earlier.range.lowerBound ..< split.lowerBound
                )
            }
            if pullsLater {
                result[index + 1] = SpeakerTurn(
                    speaker: later.speaker,
                    range: split.upperBound ..< later.range.upperBound
                )
            }
        }
        return result
    }

    /// Each silence between consecutive words, as the `[end-of-word ..< start-of-next]`
    /// gap. Words are sorted first so gaps are non-negative and in time order.
    private func interWordSilences(_ words: [WordTiming]) -> [Range<Duration>] {
        let sorted = words.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var gaps: [Range<Duration>] = []
        for pair in zip(sorted, sorted.dropFirst()) {
            let lower = pair.0.range.upperBound
            let upper = pair.1.range.lowerBound
            if upper > lower { gaps.append(lower ..< upper) }
        }
        return gaps
    }

    /// The widest silence fully inside `zone` and at least ``minSilence`` long, or
    /// `nil` when the transition has no pause worth snapping to.
    private func largestSilence(
        in zone: Range<Duration>,
        among silences: [Range<Duration>]
    ) -> Range<Duration>? {
        silences
            .filter { $0.lowerBound >= zone.lowerBound && $0.upperBound <= zone.upperBound }
            .filter { ($0.upperBound - $0.lowerBound) >= minSilence }
            .max { ($0.upperBound - $0.lowerBound) < ($1.upperBound - $1.lowerBound) }
    }
}
