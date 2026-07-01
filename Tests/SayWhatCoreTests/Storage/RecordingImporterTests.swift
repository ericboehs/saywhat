import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import SayWhatCore

@Suite("RecordingImporter")
struct RecordingImporterTests {
    private static func makeSession() -> RecordingSession {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        return RecordingSession(directory: dir)
    }

    /// Write `seconds` of a constant-level mono tone to a fresh m4a at `sampleRate`,
    /// standing in for a foreign recording the importer has to decode and resample.
    private static func writeSource(
        seconds: Double,
        sampleRate: Double,
        value: Float = 0.3
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        let total = AVAudioFrameCount(seconds * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total),
              let channel = buffer.floatChannelData
        else { throw StorageError.encodeFailed }
        buffer.frameLength = total
        for index in 0 ..< Int(total) {
            channel[0][index] = value
        }
        try file.write(from: buffer)
        return url
    }

    private func readAll(
        _ source: CaptureSource,
        from session: RecordingSession
    ) async throws -> [Float] {
        var samples: [Float] = []
        for try await frame in RecordingReader().frames(for: source, in: session) {
            samples.append(contentsOf: frame.samples)
        }
        return samples
    }

    @Test("imports a foreign-rate file as a finalized, readable system track")
    func importsResampledAsSystem() async throws {
        let source = try Self.writeSource(seconds: 2, sampleRate: 44100)
        let session = Self.makeSession()
        defer {
            try? FileManager.default.removeItem(at: session.directory)
            try? FileManager.default.removeItem(at: source)
        }

        try await RecordingImporter()(source, into: session)

        #expect(session.isFinalized())
        #expect((session.segments()[.system]?.isEmpty == false))
        // The mic track stays empty — a mixed file is all "remote".
        #expect(session.segments()[.microphone] == nil)

        // Read back ~2 s at the 16 kHz model rate, with the tone's energy intact.
        let samples = try await readAll(.system, from: session)
        #expect(abs(samples.count - 16000 * 2) < 8192)
        let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(max(1, samples.count))).squareRoot()
        #expect(rms > 0.2)
    }

    @Test("imports a model-rate file without a sample-rate mismatch")
    func importsModelRate() async throws {
        let source = try Self.writeSource(seconds: 1, sampleRate: 16000)
        let session = Self.makeSession()
        defer {
            try? FileManager.default.removeItem(at: session.directory)
            try? FileManager.default.removeItem(at: source)
        }

        try await RecordingImporter()(source, into: session)

        let samples = try await readAll(.system, from: session)
        #expect(abs(samples.count - 16000) < 4096)
    }

    @Test("can target the microphone track explicitly")
    func importsToChosenTrack() async throws {
        let source = try Self.writeSource(seconds: 1, sampleRate: 16000)
        let session = Self.makeSession()
        defer {
            try? FileManager.default.removeItem(at: session.directory)
            try? FileManager.default.removeItem(at: source)
        }

        try await RecordingImporter()(source, into: session, as: .microphone)

        #expect(session.segments()[.microphone]?.isEmpty == false)
        #expect(session.segments()[.system] == nil)
    }

    @Test("reports decode progress that climbs to completion")
    func reportsProgress() async throws {
        let source = try Self.writeSource(seconds: 2, sampleRate: 44100)
        let session = Self.makeSession()
        defer {
            try? FileManager.default.removeItem(at: session.directory)
            try? FileManager.default.removeItem(at: source)
        }

        let fractions = Mutex<[Double]>([])
        try await RecordingImporter()(source, into: session) { fraction in
            fractions.withLock { $0.append(fraction) }
        }

        let reported = fractions.withLock { $0 }
        #expect(reported.count > 1)
        #expect(reported == reported.sorted()) // monotonic, never rewinds
        #expect(reported.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect((reported.last ?? 0) > 0.99) // reaches the end of the file
    }

    @Test("throws on a file that can't be opened, leaving no finalize marker")
    func throwsOnMissingFile() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("nope-\(UUID().uuidString).m4a")
        let session = Self.makeSession()
        defer { try? FileManager.default.removeItem(at: session.directory) }

        await #expect(throws: Error.self) {
            try await RecordingImporter()(missing, into: session)
        }
        #expect(!session.isFinalized())
    }
}
