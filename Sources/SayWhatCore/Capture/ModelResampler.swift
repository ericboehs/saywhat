import AVFoundation

/// Single-use carrier that hands one input buffer to `AVAudioConverter`'s pull
/// block exactly once. The converter invokes the block synchronously on the
/// calling (capture) thread, so the `@unchecked Sendable` assertion needed to
/// move the non-`Sendable` buffer into that `@Sendable` block is sound.
private final class PendingInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

/// Resamples arbitrary-format PCM to the canonical ``AudioStreamFormat/model``
/// (16 kHz mono Float32) that the live pipeline consumes.
///
/// Both capture adapters (``MicrophoneCapture`` at the hardware rate,
/// ``SystemAudioCapture`` at the ScreenCaptureKit rate) share it so the two
/// tracks down-convert identically. It wraps one `AVAudioConverter` fixed to a
/// single input format and is **stateful** — the converter carries anti-alias
/// filter state across calls, so feed it one session's contiguous buffers in
/// order. It touches no device or disk, which is why it lives outside the
/// coverage-excluded `Adapters/` folder and is unit-tested directly.
///
/// Not `Sendable`: each adapter confines its instance to the single capture
/// thread that delivers buffers (see those types' threading notes).
struct ModelResampler {
    /// The output format every `resample(_:)` produces.
    let modelFormat: AVAudioFormat

    private let converter: AVAudioConverter

    /// Builds a resampler from `inputFormat` to `modelFormat`, or `nil` if
    /// AVFoundation can't bridge the two (should not happen for valid PCM).
    init?(inputFormat: AVAudioFormat, modelFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: modelFormat) else {
            return nil
        }
        self.converter = converter
        self.modelFormat = modelFormat
    }

    /// Resample one input buffer to model-rate mono float samples. Returns an
    /// empty array for an empty input, or `nil` on a converter error.
    func resample(_ input: AVAudioPCMBuffer) -> [Float]? {
        guard input.frameLength > 0 else { return [] }

        let ratio = modelFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: modelFormat, frameCapacity: capacity) else {
            return nil
        }

        let pending = PendingInput(input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard let next = pending.take() else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return next
        }

        guard status != .error, let channel = output.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}
