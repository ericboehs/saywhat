import AVFoundation
import Foundation
import os

/// Errors from the durable storage layer.
public enum StorageError: Error, Sendable, Equatable {
    /// A frame from a different ``CaptureSource`` was appended to this writer.
    case trackMismatch
    /// `AVAssetWriter` could not be configured for AAC output.
    case writerSetupFailed
    /// Encoding or appending a sample buffer failed mid-session.
    case encodeFailed
}

/// `AVAssetWriter`-backed durable sink for one track — the concrete
/// ``DurableAudioWriter``.
///
/// Audio is encoded to AAC/m4a and streamed to disk continuously, **rotated**
/// into fixed-length segments per ``SegmentRotationPolicy``. Each rotation
/// closes the previous segment (writing its `moov` atom) before opening the
/// next, so a crash loses at most the single in-flight segment, never the whole
/// session — the durability invariant (DESIGN.md §4, QUALITY.md §3/§5). A clean
/// ``finalize()`` closes the last segment; ``RecordingSession`` then writes the
/// session-wide finalize marker.
///
/// An `actor`: `append`/`finalize` run off the capture thread (a consumer task
/// drains the ``AudioCapture`` stream into here), so serialization via actor
/// isolation is the right tool — there's no real-time budget on the storage
/// path, unlike the capture adapters.
public actor DurableAACWriter: DurableAudioWriter {
    private static let log = Logger(subsystem: "com.boehs.saywhat", category: "storage.aac")

    private let directory: URL
    private let source: CaptureSource
    private let rotation: SegmentRotationPolicy
    private let sampleRate: Int
    private let inputFormat: AVAudioFormat
    private let outputSettings: [String: Any]

    private var currentIndex = -1
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var segmentSampleOffset = 0

    /// - Parameters:
    ///   - directory: the session directory; segments are written as
    ///     `<source>.<index>.m4a` inside it (must already exist).
    ///   - source: the single track this writer persists.
    ///   - format: PCM format of the incoming frames (the model format).
    ///   - rotation: segment-length policy bounding crash loss.
    public init(
        directory: URL,
        source: CaptureSource,
        format: AudioStreamFormat = .model,
        rotation: SegmentRotationPolicy = SegmentRotationPolicy()
    ) throws {
        guard
            let pcm = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(format.sampleRate),
                channels: AVAudioChannelCount(format.channelCount),
                interleaved: false
            )
        else { throw StorageError.writerSetupFailed }

        self.directory = directory
        self.source = source
        self.rotation = rotation
        sampleRate = format.sampleRate
        inputFormat = pcm
        outputSettings = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 32000,
        ]
    }

    public func append(_ frame: AudioFrame) async throws {
        guard frame.source == source else { throw StorageError.trackMismatch }
        guard !frame.samples.isEmpty else { return }

        let index = rotation.segmentIndex(at: frame.startOffset)
        if index != currentIndex {
            try await openSegment(index)
        }

        guard let input else { throw StorageError.encodeFailed }
        // Drop rather than block the consumer if the encoder is briefly behind;
        // at 16 kHz mono / 32 kbps this effectively never trips.
        guard input.isReadyForMoreMediaData else {
            Self.log.error("encoder not ready; dropped \(frame.samples.count) samples")
            return
        }

        let pts = CMTime(
            value: CMTimeValue(segmentSampleOffset),
            timescale: CMTimeScale(sampleRate)
        )
        guard let sampleBuffer = makeSampleBuffer(frame.samples, at: pts) else {
            throw StorageError.encodeFailed
        }
        guard input.append(sampleBuffer) else {
            // Read into a local: the `Logger` interpolation autoclosure would
            // need `self.writer`, which swiftformat's redundantSelf then strips.
            let reason = writer?.error?.localizedDescription ?? "unknown"
            Self.log.error("append failed: \(reason, privacy: .public)")
            throw StorageError.encodeFailed
        }
        segmentSampleOffset += frame.samples.count
    }

    public func finalize() async throws {
        await closeCurrent()
        currentIndex = -1
    }

    // MARK: - Segments

    private func openSegment(_ index: Int) async throws {
        await closeCurrent()

        let url = directory.appendingPathComponent(
            RecordingSegment(source: source, index: index).fileName
        )
        try? FileManager.default.removeItem(at: url)

        guard let assetWriter = try? AVAssetWriter(outputURL: url, fileType: .m4a) else {
            throw StorageError.writerSetupFailed
        }
        let assetInput = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
        assetInput.expectsMediaDataInRealTime = true

        guard assetWriter.canAdd(assetInput) else { throw StorageError.writerSetupFailed }
        assetWriter.add(assetInput)
        guard assetWriter.startWriting() else { throw StorageError.writerSetupFailed }
        assetWriter.startSession(atSourceTime: .zero)

        writer = assetWriter
        input = assetInput
        currentIndex = index
        segmentSampleOffset = 0
        let track = source.rawValue
        Self.log.debug("opened segment \(track).\(index)")
    }

    private func closeCurrent() async {
        guard let writer, let input else { return }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        self.writer = nil
        self.input = nil
    }

    /// Build a CoreMedia sample buffer wrapping `samples` at presentation time
    /// `pts`, for `AVAssetWriterInput.append`.
    private func makeSampleBuffer(_ samples: [Float], at pts: CMTime) -> CMSampleBuffer? {
        let frames = AVAudioFrameCount(samples.count)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames) else {
            return nil
        }
        pcm.frameLength = frames
        guard let channel = pcm.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { channel.update(from: base, count: samples.count) }
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let created = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: inputFormat.formatDescription,
            sampleCount: CMItemCount(samples.count),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard created == noErr, let sampleBuffer else { return nil }

        let attached = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: pcm.audioBufferList
        )
        guard attached == noErr else { return nil }
        return sampleBuffer
    }
}
