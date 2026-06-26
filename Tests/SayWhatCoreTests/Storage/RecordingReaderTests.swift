import AVFoundation
import Foundation
import Testing
@testable import SayWhatCore

@Suite("RecordingReader")
struct RecordingReaderTests {
    private static func makeSession() throws -> RecordingSession {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-\(UUID().uuidString)", isDirectory: true)
        let session = RecordingSession(directory: dir)
        try session.createDirectory()
        return session
    }

    /// One model frame of `count` constant-valued samples at session offset `at`.
    private static func frame(
        _ value: Float,
        count: Int,
        at offset: Duration,
        source: CaptureSource = .microphone
    ) -> AudioFrame {
        AudioFrame(
            source: source,
            startOffset: offset,
            samples: [Float](repeating: value, count: count)
        )
    }

    /// Collect a track's frames into one flat sample array.
    private func readAll(
        _ source: CaptureSource,
        from session: RecordingSession,
        reader: RecordingReader
    ) async throws -> [Float] {
        var samples: [Float] = []
        for try await frame in reader.frames(for: source, in: session) {
            samples.append(contentsOf: frame.samples)
        }
        return samples
    }

    @Test("reads back roughly the samples that were written")
    func roundTrip() async throws {
        let session = try Self.makeSession()
        defer { try? FileManager.default.removeItem(at: session.directory) }

        // Write 1.0 s of a constant level across a few frames.
        let writer = try session.writer(for: .microphone)
        let total = 16000
        var offset = Duration.zero
        for _ in 0 ..< 10 {
            let chunk = Self.frame(0.3, count: total / 10, at: offset)
            try await writer.append(chunk)
            offset += chunk.duration
        }
        try await writer.finalize()

        let samples = try await readAll(.microphone, from: session, reader: RecordingReader())
        // AAC is lossy and adds priming/padding, so allow generous slack.
        #expect(abs(samples.count - total) < 4096)
        let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(max(1, samples.count))).squareRoot()
        #expect(rms > 0.2) // the constant tone survived the round trip
    }

    @Test("stitches multiple rotated segments in order")
    func stitchesSegments() async throws {
        let session = try Self.makeSession()
        defer { try? FileManager.default.removeItem(at: session.directory) }

        // Rotate every 1 s so 3 s spans three segments (the policy floors the
        // segment length to whole seconds).
        let rotation = SegmentRotationPolicy(segmentLength: .seconds(1))
        let writer = try session.writer(for: .system, rotation: rotation)
        var offset = Duration.zero
        for _ in 0 ..< 30 {
            let chunk = Self.frame(0.25, count: 1600, at: offset, source: .system)
            try await writer.append(chunk)
            offset += chunk.duration
        }
        try await writer.finalize()

        #expect((session.segments()[.system]?.count ?? 0) >= 2)
        let samples = try await readAll(.system, from: session, reader: RecordingReader())
        #expect(abs(samples.count - 16000 * 3) < 8192)
    }

    @Test("frame offsets advance monotonically from the session start")
    func monotonicOffsets() async throws {
        let session = try Self.makeSession()
        defer { try? FileManager.default.removeItem(at: session.directory) }

        let writer = try session.writer(for: .microphone)
        var offset = Duration.zero
        for _ in 0 ..< 8 {
            let chunk = Self.frame(0.2, count: 2000, at: offset)
            try await writer.append(chunk)
            offset += chunk.duration
        }
        try await writer.finalize()

        var last = Duration.zero
        var first = true
        for try await frame in RecordingReader(frameSize: 4000).frames(
            for: .microphone,
            in: session
        ) {
            if first {
                #expect(frame.startOffset == .zero)
                first = false
            } else {
                #expect(frame.startOffset > last)
            }
            last = frame.startOffset
        }
        #expect(!first) // at least one frame came back
    }

    @Test("an absent track yields no frames")
    func absentTrack() async throws {
        let session = try Self.makeSession()
        defer { try? FileManager.default.removeItem(at: session.directory) }

        let samples = try await readAll(.system, from: session, reader: RecordingReader())
        #expect(samples.isEmpty)
    }

    /// Write a constant-valued AAC segment directly, in an arbitrary format, so we
    /// can exercise decode paths our own (always-mono-16k) writer never produces.
    private static func writeSegment(
        _ source: CaptureSource,
        in session: RecordingSession,
        sampleRate: Double,
        channels: AVAudioChannelCount,
        values: [Float]
    ) throws {
        let url = session.directory.appendingPathComponent(
            RecordingSegment(source: source, index: 0).fileName
        )
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channels),
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        let frames: AVAudioFrameCount = 16000
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channelData = buffer.floatChannelData
        else { return }
        buffer.frameLength = frames
        for channel in 0 ..< Int(channels) {
            let data = channelData[channel]
            for index in 0 ..< Int(frames) {
                data[index] = values[channel]
            }
        }
        try file.write(from: buffer)
    }

    @Test("down-mixes a multi-channel segment to mono")
    func downmixesStereo() async throws {
        let session = try Self.makeSession()
        defer { try? FileManager.default.removeItem(at: session.directory) }

        // ch0 = 0.4, ch1 = 0.2 → mono average 0.3.
        try Self.writeSegment(
            .system,
            in: session,
            sampleRate: 16000,
            channels: 2,
            values: [0.4, 0.2]
        )

        let samples = try await readAll(.system, from: session, reader: RecordingReader())
        #expect(!samples.isEmpty)
        let mean = samples.reduce(0, +) / Float(samples.count)
        #expect(abs(mean - 0.3) < 0.1) // averaged channels, allowing AAC slack
    }

    @Test("rejects a segment whose sample rate isn't the model rate")
    func rejectsForeignSampleRate() async throws {
        let session = try Self.makeSession()
        defer { try? FileManager.default.removeItem(at: session.directory) }

        try Self.writeSegment(
            .microphone,
            in: session,
            sampleRate: 48000,
            channels: 1,
            values: [0.3]
        )

        await #expect(throws: StorageError.self) {
            for try await _ in RecordingReader().frames(for: .microphone, in: session) {}
        }
    }
}
