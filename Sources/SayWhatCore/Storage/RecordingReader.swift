import AVFoundation
import Foundation

/// Reads a finished session's saved AAC back as a model-format frame stream —
/// the inverse of ``DurableAACWriter``, and the audio source for the **final
/// pass** (Stage B; DESIGN.md §3, §14 Phase 3).
///
/// A track is stored as rotating `<source>.<index>.m4a` segments. This stitches
/// them back, in index order, into one continuous stream of ``AudioFrame``s at
/// the canonical 16 kHz mono model format, with offsets relative to the start of
/// the session — exactly what a batch ``Transcriber`` / ``Diarizer`` consumes.
/// Streaming (rather than returning one giant buffer) keeps memory bounded over
/// a long meeting and lets a downstream adapter process incrementally.
///
/// The decode itself is an AVFoundation seam, but it's cheap to exercise for
/// real: a write-then-read round trip through ``DurableAACWriter`` is the natural
/// test (QUALITY.md §6), so this stays a plain type rather than a coverage-
/// excluded adapter.
public struct RecordingReader: Sendable {
    /// Samples per emitted frame, at the model rate (default 8000 = 0.5 s).
    public let frameSize: Int

    public init(frameSize: Int = 8000) {
        self.frameSize = max(1, frameSize)
    }

    /// The ordered segment file URLs for one track in `session`.
    public func segmentURLs(for source: CaptureSource, in session: RecordingSession) -> [URL] {
        (session.segments()[source] ?? []).map {
            session.directory.appendingPathComponent($0.fileName)
        }
    }

    /// Decode one track's segments into a continuous frame stream. Frames are
    /// model-format and `frameSize` samples each (the final, partial frame may be
    /// shorter); `startOffset` is the running position from the session start.
    /// The stream finishes with an error if a segment can't be decoded.
    public func frames(
        for source: CaptureSource,
        in session: RecordingSession
    ) -> AsyncThrowingStream<AudioFrame, Error> {
        let urls = segmentURLs(for: source, in: session)
        let frameSize = frameSize
        return AsyncThrowingStream { continuation in
            let task = Task {
                var emitted = 0
                var pending: [Float] = []
                func emit(_ samples: [Float]) {
                    continuation.yield(AudioFrame(
                        source: source,
                        startOffset: Self.offset(sampleIndex: emitted),
                        samples: samples
                    ))
                    emitted += samples.count
                }
                do {
                    for url in urls {
                        try Task.checkCancellation()
                        try pending.append(contentsOf: Self.decode(url))
                        while pending.count >= frameSize {
                            emit(Array(pending.prefix(frameSize)))
                            pending.removeFirst(frameSize)
                        }
                    }
                    if !pending.isEmpty { emit(pending) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Session-timeline offset of a model-rate sample index.
    private static func offset(sampleIndex: Int) -> Duration {
        .seconds(Double(sampleIndex) / Double(AudioStreamFormat.model.sampleRate))
    }

    /// Decode an m4a file into model-format (16 kHz mono Float32) samples.
    ///
    /// Our own writer always stores 16 kHz mono, so decode is a direct read with
    /// a channel down-mix as a safety net. A non-16 kHz file (a foreign or
    /// corrupt segment) is rejected rather than silently mis-timed.
    private static func decode(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard Int(format.sampleRate) == AudioStreamFormat.model.sampleRate else {
            throw StorageError.encodeFailed
        }
        let length = AVAudioFrameCount(file.length)
        guard length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length)
        else { return [] }
        try file.read(into: buffer)
        return samples(of: buffer)
    }

    /// A float32 PCM buffer as mono samples, averaging channels if more than one.
    private static func samples(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channels = buffer.floatChannelData else { return [] }
        let count = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channels[0], count: count))
        }
        var mono = [Float](repeating: 0, count: count)
        for channel in 0 ..< channelCount {
            let data = channels[channel]
            for index in 0 ..< count {
                mono[index] += data[index]
            }
        }
        let scale = 1 / Float(channelCount)
        for index in 0 ..< count {
            mono[index] *= scale
        }
        return mono
    }
}
