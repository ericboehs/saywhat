import AVFoundation
import Foundation
import os
import Synchronization

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
/// **Route changes.** Connecting headphones or a USB/Bluetooth interface
/// changes the input device; `AVAudioEngine` responds by posting
/// `AVAudioEngineConfigurationChange` and **stopping itself**. Without recovery
/// the tap goes dead and the mic track silently ends mid-recording (observed:
/// the mic stopped the instant headphones connected). ``reconfigure()`` listens
/// for that notification, re-reads the new hardware format, rebuilds the
/// resampler, reinstalls the tap, and restarts the engine — keeping the same
/// stream and durable writer alive across the switch.
///
/// **Threading.** The tap block runs on Core Audio's real-time render thread.
/// It does no allocation-heavy or blocking work beyond the resample and a
/// non-blocking `continuation.yield`. Per-session fields (`resampler`,
/// `continuation`, `emittedSamples`) are first written in ``start()`` before the
/// tap is installed and read on the render thread. ``reconfigure()`` may later
/// rewrite `resampler`, but only after `removeTap` has quiesced the render
/// thread (so the block can't be running concurrently), and under `lifecycle` —
/// which also serializes start/stop. This confinement is why the type is
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

    private var resampler: ModelResampler?
    private var continuation: AsyncStream<AudioFrame>.Continuation?
    private var emittedSamples = 0
    private var emittedFrames = 0

    /// Observer token for `AVAudioEngineConfigurationChange`, removed in
    /// ``stop()``. Its handler runs on a dedicated serial queue so reconfiguration
    /// never races a concurrent notification.
    private var configObserver: NSObjectProtocol?
    private let configQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "com.boehs.saywhat.mic-reconfigure"
        return queue
    }()

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
            let (stream, continuation) = AsyncStream<AudioFrame>.makeStream()
            self.continuation = continuation
            emittedSamples = 0
            emittedFrames = 0

            do {
                try installTapAndStart()
            } catch {
                continuation.finish()
                self.continuation = nil
                resampler = nil
                throw error
            }

            // Recover the tap across route changes (e.g. headphones connecting).
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: configQueue
            ) { [weak self] _ in self?.reconfigure() }

            Self.log.info("started")
            return stream
        }
    }

    /// Re-read the current input format, (re)build the resampler, install the tap,
    /// and start the engine. The caller holds `lifecycle` and owns the lifetime of
    /// `continuation`; shared by the initial ``start()`` and ``reconfigure()``.
    private func installTapAndStart() throws {
        let input = engine.inputNode
        let hardwareFormat = input.inputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0 else {
            Self.log.error("no usable input device (hardware sample rate is 0)")
            throw CaptureError.inputUnavailable
        }
        guard let resampler = ModelResampler(
            inputFormat: hardwareFormat,
            modelFormat: modelFormat
        ) else {
            Self.log.error("could not build converter from hardware format to model format")
            throw CaptureError.converterUnavailable
        }
        self.resampler = resampler

        let onTap: AVAudioNodeTapBlock = { [weak self] buffer, _ in self?.ingest(buffer) }
        input.installTap(onBus: 0, bufferSize: tapBufferSize, format: hardwareFormat, block: onTap)

        do {
            try engine.start()
        } catch {
            Self.log
                .error("engine failed to start: \(error.localizedDescription, privacy: .public)")
            input.removeTap(onBus: 0)
            throw error
        }

        let hwRate = Int(hardwareFormat.sampleRate)
        Self.log.info("tap installed — hw \(hwRate) Hz \(hardwareFormat.channelCount) ch → model")
    }

    /// Recover capture after a route change: AVAudioEngine has already stopped
    /// itself, so tear down the dead tap and reinstall against the now-current
    /// device, keeping the same stream alive. Runs on `configQueue`, serialized
    /// with start/stop by `lifecycle`; a no-op once the session has stopped.
    /// `emittedSamples` carries over, so the brief switch gap is the only
    /// misalignment — far better than losing the rest of the track.
    private func reconfigure() {
        lifecycle.withLock { _ in
            guard continuation != nil else { return }
            Self.log.info("audio route changed — reinstalling mic tap")
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
            do {
                try installTapAndStart()
            } catch {
                Self.log.error(
                    "mic reconfigure failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    public func stop() async {
        lifecycle.withLock { _ in
            if let configObserver {
                NotificationCenter.default.removeObserver(configObserver)
                self.configObserver = nil
            }
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
            continuation?.finish()
            continuation = nil
            resampler = nil
            Self.log
                .info(
                    "mic capture stopped — emitted \(self.emittedFrames) frames, \(self.emittedSamples) samples"
                )
        }
    }

    /// Resample one hardware buffer to the model format and emit it. Runs on the
    /// real-time render thread; see the type's threading note.
    private func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let resampler, let continuation, buffer.frameLength > 0 else { return }

        guard let samples = resampler.resample(buffer) else {
            Self.log.error("resample failed")
            return
        }
        guard !samples.isEmpty else { return }

        let count = samples.count
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
