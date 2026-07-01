import AVFoundation
import Foundation
import Testing
@testable import SayWhatCore

/// A manual, machine-local probe of the **import/decode** path over a real audio file
/// — the empirical check the scripted unit tests can't make: does ``RecordingImporter``
/// actually decode the *whole* file, or stop early?
///
/// Disabled unless `SAYWHAT_AUDIO` (a path to an audio file) is set, so CI — which has
/// no audio — never runs it. It replays the importer's decode loop with per-chunk
/// logging, then imports for real and reads the track back, comparing durations. Run:
///
///     SAYWHAT_AUDIO=/path/to/meeting.wav swift test --filter RealTranscription
@Suite("RealTranscription")
struct RealTranscriptionHarness {
    private static var audio: String? {
        ProcessInfo.processInfo.environment["SAYWHAT_AUDIO"]
    }

    @Test(
        "imports a real file end to end, printing decode coverage",
        .enabled(if: audio != nil)
    )
    func importRealFile() async throws {
        let source = try URL(fileURLWithPath: #require(Self.audio))
        let session = RecordingSession(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("saywhat-harness-\(UUID().uuidString)", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: session.directory) }

        try Self.probeDecodeLoop(source)
        try await RecordingImporter()(source, into: session)

        let reader = RecordingReader()
        var frames: [AudioFrame] = []
        for try await frame in reader.frames(for: .system, in: session) {
            frames.append(frame)
        }
        let importedSeconds = (frames.last.map { $0.startOffset + $0.duration })?.seconds ?? 0
        print(String(
            format: "imported system track %.2fs (%d frames)",
            importedSeconds,
            frames.count
        ))
        #expect(importedSeconds > 0)
    }

    /// Replay the importer's read → resample loop with logging, to see exactly where
    /// it stops (the production importer is silent).
    private static func probeDecodeLoop(_ source: URL) throws {
        let probe = try AVAudioFile(forReading: source)
        print(String(
            format: "AVAudioFile: length=%lld frames, rate=%.0f Hz, %d ch",
            probe.length,
            probe.processingFormat.sampleRate,
            probe.processingFormat.channelCount
        ))
        let modelFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(AudioStreamFormat.model.sampleRate),
            channels: 1,
            interleaved: false
        ))
        let resampler = try #require(ModelResampler(
            inputFormat: probe.processingFormat,
            modelFormat: modelFormat
        ))
        var emitted = 0, iterations = 0
        while probe.framePosition < probe.length {
            let toRead = min(16000, AVAudioFrameCount(probe.length - probe.framePosition))
            let buffer = try #require(AVAudioPCMBuffer(
                pcmFormat: probe.processingFormat,
                frameCapacity: toRead
            ))
            try probe.read(into: buffer, frameCount: toRead)
            iterations += 1
            if buffer
                .frameLength == 0 { print("  chunk \(iterations): frameLength 0 → break"); break }
            let out = resampler.resample(buffer)?.count ?? -1
            emitted += out
            if iterations <= 2 || iterations % 10 == 0 {
                print(String(
                    format: "  chunk %d: read %d, pos %lld/%lld, out %d, emitted %d",
                    iterations,
                    buffer.frameLength,
                    probe.framePosition,
                    probe.length,
                    out,
                    emitted
                ))
            }
        }
        print(
            "decode loop ran \(iterations) chunks, emitted \(emitted) samples = \(Double(emitted) / 16000)s"
        )
    }
}
