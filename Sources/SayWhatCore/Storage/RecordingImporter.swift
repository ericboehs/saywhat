import AVFoundation
import Foundation

/// Imports an external audio file as a finalized SayWhat session, so the final
/// pass can transcribe and diarize a recording captured elsewhere (e.g. an
/// earl-scribe meeting) — the seam for trying the pipeline on real audio without
/// recording a live call.
///
/// SayWhat keeps mic and system audio separate end to end, but a foreign file is
/// a single mixed track. It's written as the **system** track — the one the final
/// pass diarizes — so every voice (including yours) surfaces as a remote speaker
/// to be split and named; the mic track is simply left empty. The source is
/// decoded and resampled to the canonical 16 kHz mono model format and written
/// through ``DurableAACWriter``, the exact path live capture uses, so the result
/// is indistinguishable from a native recording and reprocessable like any other.
public struct RecordingImporter: Sendable {
    /// Frames read from the source per decode chunk (~1 s at 16 kHz). Bounds peak
    /// memory over a long meeting; the resampler is fed sequentially so chunk size
    /// doesn't affect the output.
    private let chunkSize: AVAudioFrameCount

    public init(chunkSize: AVAudioFrameCount = 16000) {
        self.chunkSize = max(1, chunkSize)
    }

    /// Decode `sourceURL` into `session` as a finalized `source`-track recording.
    /// Creates the session directory if needed; on success it holds that track's
    /// rotating AAC segments plus the finalize marker, ready for the final pass.
    /// Throws if the file can't be opened or decoded, or the writer fails — the
    /// caller surfaces it; a partially-written session is left for the next launch
    /// to ignore (no finalize marker) rather than half-imported.
    public func callAsFunction(
        _ sourceURL: URL,
        into session: RecordingSession,
        as source: CaptureSource = .system,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let file = try AVAudioFile(forReading: sourceURL)
        guard
            let modelFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(AudioStreamFormat.model.sampleRate),
                channels: AVAudioChannelCount(AudioStreamFormat.model.channelCount),
                interleaved: false
            ),
            let resampler = ModelResampler(
                inputFormat: file.processingFormat,
                modelFormat: modelFormat
            )
        else {
            throw StorageError.encodeFailed
        }

        try session.createDirectory()
        // Offline write: the decode loop feeds frames far faster than real time, so the
        // encoder must *wait* when it falls behind rather than drop (live capture's
        // policy), which would silently truncate the import. See DurableAACWriter.
        let writer = try session.writer(for: source, realTime: false)
        var emitted = 0

        // Read up to the file's frame count, bounding each read by what remains so
        // we never call `read` past EOF (which throws rather than yielding zero).
        while file.framePosition < file.length {
            let remaining = AVAudioFrameCount(file.length - file.framePosition)
            let toRead = min(chunkSize, remaining)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: toRead
            ) else {
                throw StorageError.encodeFailed
            }
            try file.read(into: buffer, frameCount: toRead)
            if buffer.frameLength == 0 { break }
            guard let samples = resampler.resample(buffer) else { throw StorageError.encodeFailed }
            if samples.isEmpty { continue }
            try await writer.append(AudioFrame(
                source: source,
                startOffset: .seconds(Double(emitted) / Double(AudioStreamFormat.model.sampleRate)),
                samples: samples
            ))
            emitted += samples.count
            // Decode position over the source's frame count — a true fraction of the
            // file consumed, independent of resampling.
            if file.length > 0 {
                onProgress?(min(1, Double(file.framePosition) / Double(file.length)))
            }
        }

        try await writer.finalize()
        try session.markFinalized()
    }
}
