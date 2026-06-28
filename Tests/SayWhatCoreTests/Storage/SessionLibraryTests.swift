import Foundation
import Testing
@testable import SayWhatCore

/// Listing past sessions: only real recordings appear, newest first, with the
/// start time decoded from the directory name and the editable flag reflecting
/// whether a transcript document was saved.
@Suite("Session library")
struct SessionLibraryTests {
    /// A throwaway directory tree, cleaned up when the test ends.
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Create `session-<stamp>` under `root`, optionally giving it a recording
    /// and/or a saved transcript so the listing rules can be exercised.
    private func makeSession(
        _ stamp: Int,
        in root: URL,
        recording: Bool = false,
        transcript: Bool = false
    ) throws {
        let directory = root.appendingPathComponent("session-\(stamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if recording {
            try Data().write(to: directory.appendingPathComponent("recording.m4a"))
        }
        if transcript {
            try TranscriptStore(directory: directory)
                .save(SessionTranscript(transcript: Transcript()))
        }
    }

    @Test("lists real sessions newest first, decoding date and editability")
    func listsNewestFirst() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSession(1000, in: root, recording: true)
        try makeSession(3000, in: root, recording: true, transcript: true)
        try makeSession(2000, in: root, transcript: true)

        let sessions = SessionLibrary.sessions(in: root)

        #expect(sessions.map(\.id) == ["session-3000", "session-2000", "session-1000"])
        #expect(sessions.map(\.hasTranscript) == [true, true, false])
        #expect(sessions.first?.date == Date(timeIntervalSince1970: 3000))
    }

    @Test("skips empty/aborted dirs and non-session names")
    func skipsNonSessions() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSession(1000, in: root) // empty — no recording, no transcript
        try makeSession(2000, in: root, recording: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("not-a-session"),
            withIntermediateDirectories: true
        )

        #expect(SessionLibrary.sessions(in: root).map(\.id) == ["session-2000"])
    }

    @Test("a missing root lists nothing rather than throwing")
    func missingRootIsEmpty() {
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("nope-\(UUID().uuidString)", isDirectory: true)
        #expect(SessionLibrary.sessions(in: absent).isEmpty)
    }
}
