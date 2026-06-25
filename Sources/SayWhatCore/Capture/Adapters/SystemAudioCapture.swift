import AVFoundation
import Foundation
import os
import ScreenCaptureKit
import Synchronization

/// `ScreenCaptureKit`-backed system-audio track — the concrete ``AudioCapture``
/// for ``CaptureSource/system`` (the remote participants / room output).
///
/// It opens an `SCStream` over the main display with audio capture enabled,
/// excludes this process's own playback so we never record our own output, and
/// resamples each delivered buffer to the canonical ``AudioStreamFormat/model``
/// (16 kHz mono Float32) with the shared ``ModelResampler``. Per the
/// separate-tracks invariant it owns exactly one track and never touches the
/// microphone; that's a separate ``AudioCapture`` instance (see DESIGN.md §4).
///
/// **Threading.** ScreenCaptureKit delivers sample buffers on the serial
/// `sampleQueue` we hand it. Per-session fields (`resampler`, `continuation`,
/// `emittedSamples`) are written once in ``start()`` before capture begins and
/// then read/written only from that single delivery queue until ``stop()``, so
/// they need no lock; `lifecycle` serializes start/stop against each other.
/// That confinement is why the type is `@unchecked Sendable` rather than an
/// actor — an actor hop on the audio path would violate the budget
/// (QUALITY.md §4).
public final class SystemAudioCapture: NSObject, AudioCapture, @unchecked Sendable {
    public let source: CaptureSource = .system

    private static let log = Logger(subsystem: "com.boehs.saywhat", category: "capture.system")

    private let lifecycle = Mutex<Void>(())
    private let sampleQueue = DispatchQueue(label: "com.boehs.saywhat.system-audio")

    /// ScreenCaptureKit capture format. 48 kHz stereo is SCK's native delivery;
    /// the resampler down-converts to the 16 kHz mono model format.
    private let captureSampleRate = 48000
    private let captureChannels = 2

    private var stream: SCStream?
    private var resampler: ModelResampler?
    private var continuation: AsyncStream<AudioFrame>.Continuation?
    private var emittedSamples = 0
    private var emittedFrames = 0

    private let modelFormat: AVAudioFormat

    override public init() {
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
        super.init()
    }

    public func start() async throws -> AsyncStream<AudioFrame> {
        // Triggers the Screen Recording TCC prompt on first run; throws if the
        // user has denied it. No display means nothing to capture.
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        guard let display = content.displays.first else {
            Self.log.error("no display available for system-audio capture")
            throw CaptureError.inputUnavailable
        }

        return try lifecycle.withLock { _ in
            let filter = SCContentFilter(
                display: display,
                excludingApplications: [],
                exceptingWindows: []
            )

            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.sampleRate = captureSampleRate
            config.channelCount = captureChannels
            config.excludesCurrentProcessAudio = true
            // We ignore video, but SCStream still requires a valid configuration;
            // keep it tiny and slow to minimise the unused capture's cost.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            self.stream = stream

            let (audioStream, continuation) = AsyncStream<AudioFrame>.makeStream()
            self.continuation = continuation
            resampler = nil
            emittedSamples = 0
            emittedFrames = 0

            stream.startCapture { [weak self] error in
                guard let self, let error else { return }
                Self.log
                    .error(
                        "stream failed to start: \(error.localizedDescription, privacy: .public)"
                    )
                // Keep continuation access on the delivery queue (threading note).
                sampleQueue.async { self.continuation?.finish() }
            }

            let rate = captureSampleRate
            let channels = captureChannels
            Self.log.info("started — \(rate) Hz \(channels) ch → model 16 kHz mono")
            return audioStream
        }
    }

    public func stop() async {
        let toStop: SCStream? = lifecycle.withLock { _ in
            let current = stream
            stream = nil
            continuation?.finish()
            continuation = nil
            resampler = nil
            let frames = emittedFrames
            let total = emittedSamples
            Self.log.info("system capture stopped — emitted \(frames) frames, \(total) samples")
            return current
        }
        // `stopCapture` is async and must not run under the lock.
        if let toStop {
            try? await toStop.stopCapture()
        }
    }
}

// MARK: - SCStreamOutput / SCStreamDelegate

extension SystemAudioCapture: SCStreamOutput, SCStreamDelegate {
    public func stream(
        _: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer) else { return }
        ingest(sampleBuffer)
    }

    public func stream(_: SCStream, didStopWithError error: Error) {
        Self.log.error("stream stopped with error: \(error.localizedDescription, privacy: .public)")
        sampleQueue.async { [weak self] in self?.continuation?.finish() }
    }

    /// Convert one ScreenCaptureKit audio buffer to a model-format ``AudioFrame``
    /// and emit it. Runs on `sampleQueue`; see the type's threading note.
    private func ingest(_ sampleBuffer: CMSampleBuffer) {
        guard let continuation else { return }
        guard let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }

        // Build the resampler lazily from the first buffer's real format — SCK
        // can deliver a layout that differs from the requested configuration.
        if resampler == nil {
            resampler = ModelResampler(inputFormat: pcm.format, modelFormat: modelFormat)
            if resampler == nil {
                let rate = Int(pcm.format.sampleRate)
                Self.log.error("could not build converter from \(rate) Hz to model")
                return
            }
        }
        guard let samples = resampler?.resample(pcm) else {
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

        if emittedFrames == 1 {
            Self.log.info("first frame: \(count) samples @ 16 kHz")
        } else if emittedFrames.isMultiple(of: 256) {
            let frames = emittedFrames
            let total = emittedSamples
            Self.log.debug("heartbeat — \(frames) frames, \(total) samples")
        }

        continuation.yield(AudioFrame(source: source, startOffset: offset, samples: samples))
    }

    /// Copy a CoreMedia audio sample buffer into an `AVAudioPCMBuffer` in its
    /// native format, or `nil` if the format/data can't be read.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard
            let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc),
            let format = AVAudioFormat(streamDescription: asbd)
        else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard
            frameCount > 0,
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return nil }
        pcm.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcm.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return pcm
    }
}
