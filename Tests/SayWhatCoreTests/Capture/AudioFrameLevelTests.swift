import Foundation
import Testing
@testable import SayWhatCore

@Suite("AudioFrame level metering")
struct AudioFrameLevelTests {
    private func frame(_ samples: [Float]) -> AudioFrame {
        AudioFrame(source: .microphone, startOffset: .zero, samples: samples)
    }

    @Test("empty and silent frames read as zero")
    func silenceIsZero() {
        #expect(frame([]).rms == 0)
        #expect(frame([]).meterLevel() == 0)
        #expect(frame([Float](repeating: 0, count: 256)).rms == 0)
        #expect(frame([Float](repeating: 0, count: 256)).meterLevel() == 0)
    }

    @Test("RMS of a constant signal is its amplitude")
    func rmsOfConstant() {
        #expect(abs(frame([Float](repeating: 0.5, count: 1000)).rms - 0.5) < 1e-6)
    }

    @Test("RMS of a full-scale square wave is 1")
    func rmsOfSquareWave() {
        let square = (0 ..< 1000).map { $0.isMultiple(of: 2) ? Float(1) : Float(-1) }
        #expect(abs(frame(square).rms - 1) < 1e-6)
    }

    @Test("meter level maps the dBFS floor to 0 and full scale to 1")
    func meterEndpoints() {
        // Full scale (rms 1 → 0 dBFS) reads 1.
        #expect(abs(frame([Float](repeating: 1, count: 64)).meterLevel() - 1) < 1e-6)
        // At the floor (rms 0.001 → −60 dBFS) reads ~0.
        #expect(frame([Float](repeating: 0.001, count: 64)).meterLevel() < 0.01)
        // Below the floor clamps to 0.
        #expect(frame([Float](repeating: 0.0001, count: 64)).meterLevel() == 0)
    }

    @Test("meter level is monotonic in amplitude")
    func meterMonotonic() {
        let quiet = frame([Float](repeating: 0.05, count: 64)).meterLevel()
        let loud = frame([Float](repeating: 0.5, count: 64)).meterLevel()
        #expect(quiet > 0)
        #expect(loud > quiet)
        #expect(loud <= 1)
    }
}
