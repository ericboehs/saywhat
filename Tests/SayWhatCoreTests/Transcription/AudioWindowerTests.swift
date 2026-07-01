import Foundation
import Testing
@testable import SayWhatCore

@Suite("AudioWindower")
struct AudioWindowerTests {
    /// A small-scale windower so synthetic buffers stay tiny: 100-sample cap,
    /// 10-sample floor, 10-sample energy frames, 50-sample silence look-back.
    private let windower = AudioWindower(maxWindow: 100, minWindow: 10, frame: 10, searchRadius: 50)

    /// Build a buffer of `count` samples where the ranges in `loud` carry a
    /// full-scale tone and everything else is silence — a stand-in for speech
    /// bursts separated by pauses.
    private func signal(_ count: Int, loud: [Range<Int>]) -> [Float] {
        var samples = [Float](repeating: 0, count: count)
        for range in loud {
            for index in range {
                samples[index] = 1
            }
        }
        return samples
    }

    /// The loud frames a cut must never fall inside — peak energy means speech.
    private func isSilent(_ samples: [Float], at index: Int, frame: Int) -> Bool {
        let end = min(index + frame, samples.count)
        return !(index ..< end).contains { samples[$0] != 0 }
    }

    @Test("a buffer within the cap is returned whole")
    func shortBufferIsOneWindow() {
        #expect(windower.windows(signal(80, loud: [])) == [0 ..< 80])
    }

    @Test("an empty buffer yields no windows")
    func emptyBufferIsNoWindows() {
        #expect(windower.windows([]).isEmpty)
    }

    @Test("windows tile the whole buffer contiguously with none over the cap")
    func windowsTileContiguously() {
        // 250 samples (> cap) with periodic silent gaps to cut in.
        let loud = stride(from: 0, to: 250, by: 30).map { $0 ..< min($0 + 20, 250) }
        let samples = signal(250, loud: loud)
        let windows = windower.windows(samples)

        #expect(windows.first?.lowerBound == 0)
        #expect(windows.last?.upperBound == 250)
        for (earlier, later) in zip(windows, windows.dropFirst()) {
            #expect(earlier.upperBound == later.lowerBound)
        }
        for window in windows {
            #expect(window.count <= 100)
        }
    }

    @Test("every emitted window respects the minimum length")
    func windowsRespectMinimum() {
        let samples = signal(250, loud: [0 ..< 250]) // no silence anywhere
        for window in windower.windows(samples) {
            #expect(window.count >= 10)
        }
    }

    @Test("interior cuts land in silence, never mid-burst")
    func cutsFallInSilence() {
        // Bursts of 20 loud samples every 30, leaving frame-aligned 10-sample
        // silent gaps. Over 260 samples this forces several windows; each interior
        // cut must land in a gap, never inside a burst.
        let loud = stride(from: 0, to: 260, by: 30).map { $0 ..< min($0 + 20, 260) }
        let samples = signal(260, loud: loud)
        let windows = windower.windows(samples)

        #expect(windows.count > 1)
        for window in windows.dropLast() {
            #expect(isSilent(samples, at: window.upperBound, frame: 10))
        }
    }

    @Test("a clean pause near the cap is preferred over the hard boundary")
    func prefersNearbyPause() {
        // Loud everywhere except a single silent frame at 70–80; with a 100 cap
        // and 50-sample look-back, the cut should snap to that pause, not to 100.
        let samples = signal(260, loud: [0 ..< 70, 80 ..< 260])
        let windows = windower.windows(samples)

        #expect(windows.first == 0 ..< 70)
    }
}
