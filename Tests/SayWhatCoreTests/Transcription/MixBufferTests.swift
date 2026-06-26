import Foundation
import Testing
@testable import SayWhatCore

@Suite("MixBuffer")
struct MixBufferTests {
    @Test("sums paired samples from both tracks")
    func sumsPairs() {
        var buffer = MixBuffer()
        buffer.appendMic([0.1, 0.2, 0.3])
        buffer.appendSystem([0.4, 0.5, 0.6])
        let out = buffer.drain()
        #expect(out.count == 3)
        #expect(out[0] == Float(0.1) + Float(0.4))
        #expect(out[2] == Float(0.3) + Float(0.6))
    }

    @Test("emits nothing until both tracks have data")
    func waitsForBoth() {
        var buffer = MixBuffer()
        buffer.appendMic([0.1, 0.2, 0.3])
        #expect(buffer.drain().isEmpty)
        buffer.appendSystem([0.4])
        #expect(buffer.drain() == [Float(0.1) + Float(0.4)])
        // The unpaired mic surplus stays buffered for its future system pairs.
        #expect(buffer.drain().isEmpty)
    }

    @Test("pairs across multiple uneven appends")
    func unevenAppends() {
        var buffer = MixBuffer()
        buffer.appendMic([0.1, 0.2])
        buffer.appendSystem([0.01, 0.02, 0.03, 0.04])
        #expect(buffer.drain() == [Float(0.1) + 0.01, Float(0.2) + 0.02])
        buffer.appendMic([0.3, 0.4])
        #expect(buffer.drain() == [Float(0.3) + 0.03, Float(0.4) + 0.04])
    }

    @Test("flushes the survivor once its counterpart finishes")
    func flushesTailOnFinish() {
        var buffer = MixBuffer()
        buffer.appendMic([0.1, 0.2, 0.3, 0.4])
        buffer.appendSystem([0.01, 0.02])
        #expect(buffer.drain() == [Float(0.1) + 0.01, Float(0.2) + 0.02])
        // System ends with mic samples 3 and 4 still unpaired — flush them as-is.
        buffer.finishSystem()
        #expect(buffer.drain() == [0.3, 0.4])
    }

    @Test("clips a summed peak to the valid range")
    func clipsPeak() {
        var buffer = MixBuffer()
        buffer.appendMic([0.8, -0.9])
        buffer.appendSystem([0.7, -0.8])
        let out = buffer.drain()
        #expect(out[0] == 1) // 0.8 + 0.7 clipped to +1
        #expect(out[1] == -1) // -0.9 + -0.8 clipped to -1
    }

    @Test("is complete only after both finish and the buffer drains")
    func completion() {
        var buffer = MixBuffer()
        buffer.appendMic([1])
        buffer.appendSystem([2])
        buffer.finishMic()
        #expect(!buffer.isComplete) // system not finished, sample still buffered
        buffer.finishSystem()
        #expect(!buffer.isComplete) // paired sample not yet drained
        _ = buffer.drain()
        #expect(buffer.isComplete)
    }

    @Test("starts empty and complete-free")
    func startsEmpty() {
        var buffer = MixBuffer()
        #expect(buffer.drain().isEmpty)
        #expect(!buffer.isComplete)
    }
}
