import Foundation
import Testing
@testable import SayWhatCore

@Suite("TranscriptLog")
struct TranscriptLogTests {
    /// A fresh temp directory for the log file, removed after the test.
    private func withTempDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @Test("formats one line as [timecode] speaker: text")
    func formatsLine() {
        #expect(
            TranscriptLog.line(timecode: "2:14", speaker: "You", text: "hello there")
                == "[2:14] You: hello there\n"
        )
    }

    @Test("appends finalized lines in order, creating the file on first write")
    func appendsInOrder() throws {
        try withTempDirectory { directory in
            let log = TranscriptLog(directory: directory)
            try log.append(timecode: "0:00", speaker: "You", text: "hello")
            try log.append(timecode: "0:03", speaker: "Speaker 2", text: "hi there")

            let contents = try String(contentsOf: log.fileURL, encoding: .utf8)
            #expect(contents == "[0:00] You: hello\n[0:03] Speaker 2: hi there\n")
        }
    }

    @Test("writes transcript.md into the session directory by default")
    func defaultFilename() throws {
        try withTempDirectory { directory in
            let log = TranscriptLog(directory: directory)
            #expect(log.fileURL.lastPathComponent == "transcript.md")
        }
    }
}
