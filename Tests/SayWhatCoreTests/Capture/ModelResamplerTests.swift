import AVFoundation
import Testing
@testable import SayWhatCore

@Suite("ModelResampler")
struct ModelResamplerTests {
    /// 16 kHz mono Float32 — the model format every adapter targets.
    private static func modelFormat() throws -> AVAudioFormat {
        try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(AudioStreamFormat.model.sampleRate),
            channels: 1,
            interleaved: false
        ))
    }

    /// A buffer of `frames` samples all set to `value`, in `format`.
    private static func constantBuffer(
        _ value: Float,
        frames: AVAudioFrameCount,
        format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channels = try #require(buffer.floatChannelData)
        for channel in 0 ..< Int(format.channelCount) {
            let data = channels[channel]
            for index in 0 ..< Int(frames) {
                data[index] = value
            }
        }
        return buffer
    }

    @Test("down-samples 48 kHz to 16 kHz at the 1:3 ratio over a stream")
    func downsamplesByThree() throws {
        let input = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let resampler = try #require(ModelResampler(
            inputFormat: input,
            modelFormat: Self.modelFormat()
        ))

        // Feed 1.0 s in ten 0.1 s buffers. The converter's filter priming makes
        // the first buffer short (steady state is ~1600/buffer), so assert the
        // aggregate approaches one model-rate second rather than a per-buffer
        // count — that's the real 1:3 behaviour the adapters rely on.
        var total = 0
        for _ in 0 ..< 10 {
            let out = try #require(resampler.resample(Self.constantBuffer(
                0.5,
                frames: 4800,
                format: input
            )))
            total += out.count
        }
        #expect(abs(total - 16000) <= 400)
    }

    @Test("preserves a DC level through the rate conversion (within tolerance)")
    func preservesLevel() throws {
        let input = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let resampler = try #require(ModelResampler(
            inputFormat: input,
            modelFormat: Self.modelFormat()
        ))

        let out = try #require(resampler.resample(Self.constantBuffer(
            0.5,
            frames: 9600,
            format: input
        )))
        // Skip the filter's edge transient; the interior should sit near 0.5.
        let interior = out.dropFirst(64).dropLast(64)
        #expect(!interior.isEmpty)
        #expect(interior.allSatisfy { abs($0 - 0.5) < 0.05 })
    }

    @Test("an empty input yields an empty result, not nil")
    func emptyInput() throws {
        let input = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let resampler = try #require(ModelResampler(
            inputFormat: input,
            modelFormat: Self.modelFormat()
        ))

        let empty = try #require(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 1024))
        empty.frameLength = 0
        #expect(resampler.resample(empty) == [])
    }

    @Test("a matching-rate stereo input collapses to mono at the same rate")
    func stereoToMonoSameRate() throws {
        let input = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 2))
        let resampler = try #require(ModelResampler(
            inputFormat: input,
            modelFormat: Self.modelFormat()
        ))

        let out = try #require(resampler.resample(Self.constantBuffer(
            0.25,
            frames: 1600,
            format: input
        )))
        // No rate change: frame count is preserved 1:1.
        #expect(abs(out.count - 1600) <= 4)
        let interior = out.dropFirst(16).dropLast(16)
        #expect(interior.allSatisfy { abs($0 - 0.25) < 0.05 })
    }
}
