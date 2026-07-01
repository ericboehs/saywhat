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
        let gaps = interWordGaps(words)

        for index in 0 ..< (result.count - 1) {
            let earlier = result[index]
            let later = result[index + 1]
            guard earlier.speaker != later.speaker else { continue }

            // The zone in which reassignment is plausible: a window around the fuzzy
            // stretch between the earlier turn's end and the later turn's start.
            let inner = min(earlier.range.upperBound, later.range.lowerBound)
            let outer = max(earlier.range.upperBound, later.range.lowerBound)
            let zone = (inner - searchWindow) ..< (outer + searchWindow)

            // Prefer a real pause; failing that, fall back to a sentence-final word
            // gap before the (always-late) diarizer edge — rapid turn-taking often
            // has no snap-able silence but does land on a "…?" / "…." boundary.
            guard let split = largestSilence(in: zone, among: gaps)
                ?? sentenceSplit(in: zone, before: outer, among: gaps)
            else { continue }

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

    /// One inter-word gap: the `[end-of-word ..< start-of-next]` silence, tagged with
    /// whether the word *before* it ends a sentence (a `.`, `?`, or `!`).
    private struct Gap {
        let range: Range<Duration>
        let endsSentence: Bool
        var width: Duration {
            range.upperBound - range.lowerBound
        }
    }

    /// Each gap between consecutive words. Words are sorted first so gaps are
    /// non-negative and in time order; the sentence flag reads the preceding word.
    private func interWordGaps(_ words: [WordTiming]) -> [Gap] {
        let sorted = words.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var gaps: [Gap] = []
        for pair in zip(sorted, sorted.dropFirst()) {
            let lower = pair.0.range.upperBound
            let upper = pair.1.range.lowerBound
            if upper > lower {
                gaps.append(Gap(
                    range: lower ..< upper,
                    endsSentence: Self.endsSentence(pair.0.text)
                ))
            }
        }
        return gaps
    }

    /// The widest gap fully inside `zone` and at least ``minSilence`` long, or `nil`
    /// when the transition has no pause worth snapping to.
    private func largestSilence(in zone: Range<Duration>, among gaps: [Gap]) -> Range<Duration>? {
        gaps
            .filter {
                $0.range.lowerBound >= zone.lowerBound && $0.range.upperBound <= zone.upperBound
            }
            .filter { $0.width >= minSilence }
            .max { $0.width < $1.width }?
            .range
    }

    /// Fallback for pause-less turn changes: the **latest** sentence-final gap that
    /// falls inside `zone` and no later than the diarizer's own edge (`boundary`).
    /// Onset lag only ever runs *late*, so the true seam sits at or before it; among
    /// candidates the latest one over-corrects least. `nil` when none qualifies.
    private func sentenceSplit(
        in zone: Range<Duration>,
        before boundary: Duration,
        among gaps: [Gap]
    ) -> Range<Duration>? {
        gaps
            .filter(\.endsSentence)
            .filter { $0.range.lowerBound >= zone.lowerBound && $0.range.upperBound <= boundary }
            .max { $0.range.lowerBound < $1.range.lowerBound }?
            .range
    }

    /// Whether `text`'s last non-space character ends a sentence (`.`, `?`, or `!`).
    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.reversed().first(where: { !$0.isWhitespace }) else { return false }
        return last == "." || last == "?" || last == "!"
    }
}
