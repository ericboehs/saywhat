import AVFoundation
import Foundation
import os
import Synchronization

/// Single-use carrier that hands one input buffer to `AVAudioConverter`'s pull
/// block exactly once. The converter invokes the block synchronously on the
/// calling (render) thread, so the `@unchecked Sendable` assertion needed to
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

/// Errors surfaced by the hardware capture adapters.
public enum CaptureError: Error, Sendable, Equatable {
    /// The user declined (or has not yet granted) microphone access.
    case microphonePermissionDenied
    /// The input device reported an unusable format (e.g. 0 Hz — no device).
    case inputUnavailable
    /// AVFoundation could not build a converter from the hardware format to the
    /// model format. Should not happen for valid PCM formats.
    case converterUnavailable
}

/// `AVAudioEngine`-backed microphone track — the concrete ``AudioCapture`` for
/// ``CaptureSource/microphone``.
///
/// It taps the input node at the hardware format, resamples each buffer to the
/// canonical ``AudioStreamFormat/model`` (16 kHz mono Float32) with an
/// `AVAudioConverter`, and yields ``AudioFrame``s on an `AsyncStream`. Per the
/// separate-tracks invariant it owns exactly one track and never touches system
/// audio; that's a separate ``AudioCapture`` instance (see DESIGN.md §4).
///
/// **Threading.** The tap block runs on Core Audio's real-time render thread.
/// It does no allocation-heavy or blocking work beyond the resample and a
/// non-blocking `continuation.yield`. Per-session fields (`converter`,
/// `continuation`, `emittedSamples`) are written once in ``start()`` before the
/// tap is installed and read only from that single render thread until
/// ``stop()`` removes the tap — so they need no lock; `lifecycle` serializes
/// start/stop against each other. This confinement is why the type is
/// `@unchecked Sendable` rather than an actor: an actor hop on the audio path
/// would violate the real-time budget (QUALITY.md §4).
public final class MicrophoneCapture: AudioCapture, @unchecked Sendable {
    public let source: CaptureSource = .microphone

    /// Diagnostics. `Logger` is wait-free and safe to call from the render
    /// thread; the per-frame path only logs the first frame and a throttled
    /// heartbeat so it stays within the audio budget (QUALITY.md §4). View live
    /// with: `log stream --predicate 'subsystem == "com.boehs.saywhat"'`.
    private static let log = Logger(subsystem: "com.boehs.saywhat", category: "capture.microphone")

    private let engine = AVAudioEngine()
    private let modelFormat: AVAudioFormat
    private let lifecycle = Mutex<Void>(())

    private var converter: AVAudioConverter?
    private var continuation: AsyncStream<AudioFrame>.Continuation?
    private var emittedSamples = 0
    private var emittedFrames = 0

    /// Frames per tap buffer. ~85 ms at 48 kHz — small enough for a responsive
    /// live transcript, large enough to keep render-thread overhead negligible.
    private let tapBufferSize: AVAudioFrameCount = 4096

    public init() {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(AudioStreamFormat.model.sampleRate),
                channels: AVAudioChannelCount(AudioStreamFormat.model.channelCount),
                interleaved: false
            )
        else {
            preconditionFailure("16 kHz mono Float32 is always a valid PCM format")
        }
        modelFormat = format
    }

    public func start() async throws -> AsyncStream<AudioFrame> {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            Self.log.error("microphone access denied")
            throw CaptureError.microphonePermissionDenied
        }

        return try lifecycle.withLock { _ in
            let input = engine.inputNode
            let hardwareFormat = input.inputFormat(forBus: 0)
            guard hardwareFormat.sampleRate > 0 else {
                Self.log.error("no usable input device (hardware sample rate is 0)")
                throw CaptureError.inputUnavailable
            }
            guard let converter = AVAudioConverter(from: hardwareFormat, to: modelFormat) else {
                Self.log.error("could not build converter from hardware format to model format")
                throw CaptureError.converterUnavailable
            }
            self.converter = converter

            let (stream, continuation) = AsyncStream<AudioFrame>.makeStream()
            self.continuation = continuation
            emittedSamples = 0
            emittedFrames = 0

            let onTap: AVAudioNodeTapBlock = { [weak self] buffer, _ in self?.ingest(buffer) }
            input.installTap(
                onBus: 0,
                bufferSize: tapBufferSize,
                format: hardwareFormat,
                block: onTap
            )

            do {
                try engine.start()
            } catch {
                Self.log
                    .error(
                        "engine failed to start: \(error.localizedDescription, privacy: .public)"
                    )
                input.removeTap(onBus: 0)
                continuation.finish()
                self.continuation = nil
                self.converter = nil
                throw error
            }

            let hwRate = Int(hardwareFormat.sampleRate)
            Self.log
                .info(
                    "started — hw \(hwRate) Hz \(hardwareFormat.channelCount) ch → model 16 kHz mono"
                )
            return stream
        }
    }

    public func stop() async {
        lifecycle.withLock { _ in
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
            continuation?.finish()
            continuation = nil
            converter = nil
            Self.log
                .info(
                    "mic capture stopped — emitted \(self.emittedFrames) frames, \(self.emittedSamples) samples"
                )
        }
    }

    /// Resample one hardware buffer to the model format and emit it. Runs on the
    /// real-time render thread; see the type's threading note.
    private func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let continuation, buffer.frameLength > 0 else { return }

        let ratio = modelFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: modelFormat, frameCapacity: capacity) else {
            return
        }

        let pending = PendingInput(buffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard let next = pending.take() else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return next
        }

        if status == .error {
            Self.log
                .error(
                    "resample failed: \(conversionError?.localizedDescription ?? "unknown", privacy: .public)"
                )
            return
        }
        guard output.frameLength > 0, let channel = output.floatChannelData else { return }

        let count = Int(output.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channel[0], count: count))
        let offset = Duration.seconds(
            Double(emittedSamples) / Double(AudioStreamFormat.model.sampleRate)
        )
        emittedSamples += count
        emittedFrames += 1

        // First frame confirms the path is live; a ~22 s heartbeat (256 tap
        // buffers of 4096 @ 48 kHz) confirms it stays live without flooding the
        // log.
        if emittedFrames == 1 {
            Self.log.info("first frame: \(count) samples @ 16 kHz")
        } else if emittedFrames.isMultiple(of: 256) {
            // Read into locals: `Logger`'s interpolation autoclosure would
            // require `self.`, which swiftformat's redundantSelf then strips —
            // locals sidestep that fight.
            let frames = emittedFrames
            let total = emittedSamples
            Self.log.debug("heartbeat — \(frames) frames, \(total) samples")
        }

        continuation.yield(AudioFrame(source: source, startOffset: offset, samples: samples))
    }
}
