import Foundation

/// One past recording discoverable in the library: its on-disk directory, an id
/// (the directory name), the wall-clock time it started, and whether it carries an
/// editable transcript. Drives the history sidebar.
public struct RecordedSession: Sendable, Identifiable, Equatable {
    /// The session directory's name, e.g. `session-1782620980` — stable and unique,
    /// usable directly as a `List` selection id.
    public let id: String
    /// The session directory, holding its audio and (when present) `transcript.json`.
    public let directory: URL
    /// When the recording started, decoded from the `session-<unixSeconds>` name.
    public let date: Date
    /// The matched calendar event's title, from the session's saved
    /// `meeting.json`; `nil` (no calendar match) falls back to the date.
    public let title: String?
    /// Whether an editable ``SessionTranscript`` was saved: reopening loads it for
    /// editing; without it the session offers playback only.
    public let hasTranscript: Bool

    public init(id: String, directory: URL, date: Date, title: String? = nil, hasTranscript: Bool) {
        self.id = id
        self.directory = directory
        self.date = date
        self.title = title
        self.hasTranscript = hasTranscript
    }
}

/// Enumerates past recording sessions from the on-disk `Recordings/` directory.
///
/// Pure filesystem enumeration: the start time is parsed from each directory's
/// `session-<unixSeconds>` name, so listing needs no separate index or metadata
/// file. The library stays consistent with the file-based session layout — the
/// same place the audio and ``TranscriptStore`` document already live.
public enum SessionLibrary {
    /// The sessions under `root`, newest first. A directory counts as a session when
    /// its name parses as `session-<seconds>` and it holds either a combined
    /// recording or a saved transcript — skipping empty, aborted directories.
    public static func sessions(in root: URL) -> [RecordedSession] {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap { name -> RecordedSession? in
            guard let date = date(fromName: name) else { return nil }
            let directory = root.appendingPathComponent(name, isDirectory: true)
            let hasTranscript = manager.fileExists(
                atPath: directory.appendingPathComponent(TranscriptStore.defaultFileName).path
            )
            let hasRecording = manager.fileExists(
                atPath: directory.appendingPathComponent("recording.m4a").path
            )
            guard hasTranscript || hasRecording else { return nil }
            return RecordedSession(
                id: name,
                directory: directory,
                date: date,
                title: MeetingStore(directory: directory).load()?.title,
                hasTranscript: hasTranscript
            )
        }
        .sorted { $0.date > $1.date }
    }

    /// The start time encoded in a `session-<unixSeconds>` directory name, or `nil`
    /// when the name isn't in that form.
    static func date(fromName name: String) -> Date? {
        let prefix = "session-"
        guard name.hasPrefix(prefix),
              let seconds = TimeInterval(name.dropFirst(prefix.count))
        else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }
}
