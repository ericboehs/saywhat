import AVFoundation
import Foundation
import Speech

/// Live ``Transcriber`` backed by Apple's on-device `SpeechAnalyzer` /
/// `SpeechTranscriber` (the WWDC25 Speech API). One instance per track, per the
/// separate-tracks invariant; the recognizer runs on the Neural Engine and
/// never leaves the device.
///
/// Audio arrives as 16 kHz mono Float32 ``AudioFrame``s; we wrap each in an
/// `AnalyzerInput` (resampling to the analyzer's preferred format only if it
/// differs) and stream it in, surfacing every result — volatile then final — as
/// a ``TranscriptSegment``. The model is downloaded on first use via
/// `AssetInventory`; nothing else touches the network.
///
/// This is a hardware/ML adapter (coverage-excluded): the pure contract it
/// satisfies is exercised through ``Transcriber`` fakes, and its accuracy is a
/// golden-file/WER concern, not a unit-test one. See DESIGN.md §5, QUALITY.md §6.
public final class AppleSpeechTranscriber: Transcriber {
    public let source: CaptureSource

    /// The recognizer locale; defaults to the user's current locale.
    private let locale: Locale

    public init(source: CaptureSource, locale: Locale = .current) {
        self.source = source
        self.locale = locale
    }

    public func transcribe(
        _ frames: AsyncStream<AudioFrame>
    ) async throws -> AsyncThrowingStream<TranscriptSegment, Error> {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        try await Self.installModelIfNeeded(for: transcriber)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: inputStream)

        let source = source
        return AsyncThrowingStream<TranscriptSegment, Error> { continuation in
            // Feed converted audio in; close the analyzer when the track ends.
            let pump = Task {
                let converter = await FrameConverter(
                    target: SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
                )
                for await frame in frames {
                    if let input = converter?.input(for: frame) {
                        inputContinuation.yield(input)
                    }
                }
                inputContinuation.finish()
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
            }

            // Forward every recognizer result, volatile and final, as a segment.
            let forward = Task {
                do {
                    for try await result in transcriber.results {
                        continuation.yield(Self.segment(from: result, source: source))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                pump.cancel()
                forward.cancel()
            }
        }
    }

    /// Download and install the speech model for `transcriber` if it isn't
    /// already present. No-op once installed; the only network call we make.
    private static func installModelIfNeeded(for transcriber: SpeechTranscriber) async throws {
        let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        if let request {
            try await request.downloadAndInstall()
        }
    }

    /// Map one recognizer result to a ``TranscriptSegment`` on the session
    /// timeline. A non-finite time range (possible for a just-started volatile
    /// guess) collapses to an empty range at time zero.
    private static func segment(
        from result: SpeechTranscriber.Result,
        source: CaptureSource
    ) -> TranscriptSegment {
        let start = CMTimeGetSeconds(result.range.start)
        let end = CMTimeGetSeconds(result.range.end)
        let lower = start.isFinite ? max(0, start) : 0
        let upper = end.isFinite ? max(lower, end) : lower
        return TranscriptSegment(
            source: source,
            text: String(result.text.characters),
            range: .seconds(lower) ..< .seconds(upper),
            isFinal: result.isFinal
        )
    }
}

/// Converts a 16 kHz mono Float32 ``AudioFrame`` into an `AnalyzerInput` in the
/// analyzer's preferred format. When that format already matches our model
/// format (the common case for Apple ASR) it skips the resample entirely.
///
/// Not `Sendable` (it owns an `AVAudioConverter`); it is created and used
/// entirely within the single audio-pump task, never shared across tasks.
private final class FrameConverter {
    private let sourceFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    private let converter: AVAudioConverter?

    init?(target: AVAudioFormat?) {
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(AudioStreamFormat.model.sampleRate),
            channels: 1,
            interleaved: false
        ) else { return nil }
        self.sourceFormat = sourceFormat

        let targetFormat = target ?? sourceFormat
        self.targetFormat = targetFormat
        if targetFormat == sourceFormat {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                return nil
            }
            self.converter = converter
        }
    }

    func input(for frame: AudioFrame) -> AnalyzerInput? {
        guard let source = Self.buffer(samples: frame.samples, format: sourceFormat) else {
            return nil
        }
        guard let converter else { return AnalyzerInput(buffer: source) }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frame.samples.count) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        // The input block is `@Sendable`, but `AVAudioConverter.convert` runs it
        // synchronously on this thread before returning — so capturing the
        // (non-Sendable) source buffer and a one-shot flag is safe.
        nonisolated(unsafe) let inputBuffer = source
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return inputBuffer
        }
        guard error == nil, output.frameLength > 0 else { return nil }
        return AnalyzerInput(buffer: output)
    }

    /// Pack mono Float32 samples into a PCM buffer of the given format.
    private static func buffer(samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel[0].update(from: base, count: samples.count)
        }
        return buffer
    }
}
