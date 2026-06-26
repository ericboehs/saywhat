import AVFoundation
import Foundation
import Testing
@testable import SayWhatCore

@Suite("Durable AAC writer")
struct DurableAACWriterTests {
    /// A fresh, unique session directory under the system temp dir.
    private static func makeSession() throws -> RecordingSession {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("saywhat-test-\(UUID().uuidString)", isDirectory: true)
        let session = RecordingSession(directory: dir)
        try session.createDirectory()
        return session
    }

    /// One 16 kHz mono model frame of `samples` constant-valued samples, tagged
    /// at `offset` into the session.
    private static func frame(
        _ value: Float,
        samples: Int,
        at offset: Duration,
        source: CaptureSource = .microphone
    ) -> AudioFrame {
        AudioFrame(
            source: source,
            startOffset: offset,
            samples: [Float](repeating: value, count: samples)
        )
    }

    /// Feeds `seconds` of audio as 0.1 s frames into `writer`, starting at
    /// `start`. One model frame is 1600 samples (0.1 s @ 16 kHz).
    private static func feed(
        _ seconds: Double,
        into writer: DurableAACWriter,
        from start: Duration = .zero
    ) async throws {
        let frames = Int((seconds / 0.1).rounded())
        var offset = start
        for _ in 0 ..< frames {
            try await writer.append(frame(0.25, samples: 1600, at: offset))
            offset += .milliseconds(100)
        }
    }

    /// Duration in seconds of an AAC segment on disk, read back via AVAudioFile.
    private static func segmentSeconds(_ url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.fileFormat.sampleRate
    }

    @Test("a clean session writes one finalizable, readable segment")
    func cleanFinalize() async throws {
        let session = try Self.makeSession()
        defer { try? FileManager.default.removeItem(at: session.directory) }

        let writer = try session.writer(for: .microphone)
        try await Self.feed(0.5, into: writer)
        try await writer.finalize()
        try session.markFinalized()

        #expect(session.isFinalized())
        #expect(!session.needsRecovery())

        let mic = try #require(session.segments()[.microphone])
        #expect(mic.count == 1)

        let seg0 = session.directory.appendingPathComponent(
            RecordingSegment(source: .microphone, index: 0).fileName
        )
        let seconds = try Self.segmentSeconds(seg0)
        // ~0.5 s of audio; AAC encoder priming/padding widens the tolerance.
        #expect(seconds > 0.3 && seconds < 0.8)
    }

    @Test("rotation splits a long session into per-second segments")
    func rotationSplitsSegments() async throws {
        let session = try Self.makeSession()
        defer { try? FileManager.default.removeItem(at: session.directory) }

        let writer = try session.writer(
            for: .microphone,
            rotation: SegmentRotationPolicy(segmentLength: .seconds(1))
        )
        try await Self.feed(2.5, into: writer)
        try await writer.finalize()

        // Offsets 0–2.4 s at 1 s rotation → indices 0, 1, 2.
        let mic = try #require(session.segments()[.microphone])
        #expect(mic.map(\.index) == [0, 1, 2])
    }

    /// QUALITY.md §5: simulate an interrupted session, then assert the audio is
    /// recoverable and the session can be finalized.
    @Test("an interrupted session keeps its closed segments and can be finalized")
    func crashRecovery() async throws {
        let session = try Self.makeSession()
        defer { try? FileManager.default.removeItem(at: session.directory) }

        // Record 2.5 s with 1 s rotation, then "crash": never finalize. The two
        // completed segments (0, 1) were closed at each rotation; only the
        // in-flight segment (2) is at risk — that's the bounded loss.
        var writer: DurableAACWriter? = try session.writer(
            for: .microphone,
            rotation: SegmentRotationPolicy(segmentLength: .seconds(1))
        )
        try await Self.feed(2.5, into: #require(writer))
        writer = nil // drop the writer without finalize() — the crash

        // The session presents as needing recovery: segments on disk, no marker.
        #expect(session.needsRecovery())
        #expect(!session.isFinalized())
        let mic = try #require(session.segments()[.microphone])
        #expect(mic.count >= 2)

        // The completed segments are real, readable AAC — the audio survived.
        let seg0 = session.directory.appendingPathComponent(
            RecordingSegment(source: .microphone, index: 0).fileName
        )
        #expect(try Self.segmentSeconds(seg0) > 0.5)

        // Recovery: the surviving segments let us finalize the session.
        try session.markFinalized()
        #expect(session.isFinalized())
        #expect(!session.needsRecovery())
    }

    @Test("a frame from another track is rejected")
    func trackMismatchRejected() async throws {
        let session = try Self.makeSession()
        defer { try? FileManager.default.removeItem(at: session.directory) }

        let writer = try session.writer(for: .microphone)
        await #expect(throws: StorageError.trackMismatch) {
            try await writer.append(Self.frame(0.1, samples: 1600, at: .zero, source: .system))
        }
    }

    @Test("an empty frame is a no-op — no segment is opened")
    func emptyFrameIgnored() async throws {
        let session = try Self.makeSession()
        defer { try? FileManager.default.removeItem(at: session.directory) }

        let writer = try session.writer(for: .microphone)
        try await writer.append(Self.frame(0, samples: 0, at: .zero))
        try await writer.finalize()

        #expect((session.segments()[.microphone] ?? []).isEmpty)
    }

    @Test("a segment that can't be created surfaces a setup failure")
    func segmentSetupFailure() async throws {
        // Point the writer at a directory that doesn't exist, so AVAssetWriter
        // can't create the segment file under it.
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("saywhat-missing-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("nope", isDirectory: true)
        let writer = try DurableAACWriter(directory: missing, source: .microphone)

        await #expect(throws: StorageError.writerSetupFailed) {
            try await writer.append(Self.frame(0.25, samples: 1600, at: .zero))
        }
    }
}
