import Foundation

/// Splits a long mono PCM buffer into model-sized windows that are cut **in
/// silence**, so no spoken clause ever straddles a boundary.
///
/// Why this exists: FluidAudio's batch Parakeet path chunks long audio into
/// ~15 s encoder windows internally and stitches them with token deduplication.
/// A clause that lands on one of those internal seams can drift the TDT decoder
/// to blank and be **dropped entirely** (FluidAudio #594 — only partly mitigated
/// by `melChunkContext: false`). By pre-splitting the track ourselves at the
/// quietest point near each window's end, every piece is ≤ the encoder cap and
/// therefore takes FluidAudio's single-window path — no internal seams, no
/// cross-window dedup — and our own cuts fall in silence, where there is no word
/// to lose. ``ParakeetTranscriber`` transcribes each window independently and
/// re-offsets the per-token timings back onto the track timeline.
///
/// Pure and deterministic (no models, no I/O): the silence search is plain
/// frame energy, so the splitting policy is unit-tested here while the model
/// call stays in the adapter. DESIGN.md §5.
public struct AudioWindower: Sendable {
    /// Hard upper bound on a window, in samples — must stay at or below the
    /// model's single-window cap so each piece avoids the chunked path.
    public let maxWindow: Int
    /// Smallest window we will emit, in samples; also the minimum slack reserved
    /// for the final piece so a cut never strands a sub-minimum remainder.
    public let minWindow: Int
    /// Energy-analysis frame, in samples; cuts are aligned to this grid.
    public let frame: Int
    /// How far back from a window's hard end to hunt for a silent cut, in samples.
    public let searchRadius: Int

    /// Defaults target ~14 s windows (comfortably under the 15 s / 240 000-sample
    /// encoder cap), a 1 s floor, 10 ms energy frames, and a 4 s look-back for
    /// silence — enough to reach a natural pause in conversational speech.
    public init(
        maxWindow: Int = 14 * 16000,
        minWindow: Int = 16000,
        frame: Int = 160,
        searchRadius: Int = 4 * 16000
    ) {
        self.maxWindow = maxWindow
        self.minWindow = minWindow
        self.frame = frame
        self.searchRadius = searchRadius
    }

    /// Contiguous sample ranges covering `samples` in order, each no longer than
    /// ``maxWindow``. A buffer already within the cap is returned whole. Interior
    /// cuts land on the quietest frame in the look-back region before each hard
    /// boundary; if the region holds no clear valley the cut falls at the latest
    /// legal point. Every emitted range is at least ``minWindow`` long (unless the
    /// whole buffer is shorter than that).
    public func windows(_ samples: [Float]) -> [Range<Int>] {
        let count = samples.count
        guard count > maxWindow else { return count > 0 ? [0 ..< count] : [] }

        var result: [Range<Int>] = []
        var start = 0
        while count - start > maxWindow {
            let hardEnd = start + maxWindow
            // Keep the final piece valid: never cut so late that the remainder
            // would fall below the minimum window.
            let hi = Swift.min(hardEnd, count - minWindow)
            let lo = Swift.min(Swift.max(start + minWindow, hardEnd - searchRadius), hi)
            let cut = quietestCut(samples, lo: lo, hi: hi) ?? hi
            result.append(start ..< cut)
            start = cut
        }
        result.append(start ..< count)
        return result
    }

    /// The frame-aligned sample index in `lo...hi` whose frame carries the least
    /// energy — the natural place to cut. `nil` only when the range is empty.
    private func quietestCut(_ samples: [Float], lo: Int, hi: Int) -> Int? {
        guard lo < hi else { return lo == hi ? lo : nil }
        var bestIndex = lo
        var bestEnergy = Float.greatestFiniteMagnitude
        var candidate = lo
        while candidate <= hi {
            let end = Swift.min(candidate + frame, samples.count)
            var energy: Float = 0
            for index in candidate ..< end {
                energy += samples[index] * samples[index]
            }
            if energy < bestEnergy {
                bestEnergy = energy
                bestIndex = candidate
            }
            candidate += frame
        }
        return bestIndex
    }
}
