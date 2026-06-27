import Foundation

/// Appends finalized live-transcript lines to a plain-text file in the session
/// directory, so the transcript can be read (e.g. `tail -f`) *while the meeting
/// is still going* — long before the authoritative final pass runs.
///
/// One line per finalized segment, in commit order: `[M:SS] Speaker: text`. This
/// mirrors the live on-screen transcript (channel-coarse diarization, no identity
/// resolution yet), not the authoritative record. Strictly local — the file
/// lives beside the session's audio and never leaves the machine (the on-device
/// invariant, CLAUDE.md).
///
/// Append is the only mutation, so a crash mid-meeting leaves every line written
/// so far intact (the audio-is-durable tenet, applied to the derived log). Pure
/// Foundation I/O — unit-testable against a temp directory.
public struct TranscriptLog: Sendable {
    /// The file the lines are appended to.
    public let fileURL: URL

    /// - Parameters:
    ///   - directory: the session directory the log file is written into.
    ///   - filename: the log's name within it. Defaults to `transcript.md`.
    public init(directory: URL, filename: String = "transcript.md") {
        fileURL = directory.appendingPathComponent(filename)
    }

    /// Append one finalized line, creating the file on first write.
    ///
    /// - Parameters:
    ///   - timecode: the segment's start as a `M:SS`/`H:MM:SS` timecode.
    ///   - speaker: the display name for the speaker (e.g. "You", "Speaker 2").
    ///   - text: the finalized text for this turn.
    public func append(timecode: String, speaker: String, text: String) throws {
        let data = Data(Self.line(timecode: timecode, speaker: speaker, text: text).utf8)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            try data.write(to: fileURL)
            return
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// Format one log line. Pure, so the wording is unit-testable without I/O.
    static func line(timecode: String, speaker: String, text: String) -> String {
        "[\(timecode)] \(speaker): \(text)\n"
    }
}
