import Foundation

/// Reads and writes the calendar event a recording was matched to, as
/// `meeting.json` **beside its audio** in the session directory — the same
/// document-beside-the-recording pattern as ``TranscriptStore``, so a session's
/// title and attendee roster survive reopening without re-querying the calendar
/// (the event may have moved or vanished by then).
///
/// Strictly local — the file never leaves the machine (the on-device invariant).
public struct MeetingStore: Sendable {
    /// The document file within the session directory.
    public let fileURL: URL

    /// The document's default name within a session directory.
    public static let defaultFileName = "meeting.json"

    /// - Parameters:
    ///   - directory: the session directory the document is written into.
    ///   - filename: the document's name within it. Defaults to ``defaultFileName``.
    public init(directory: URL, filename: String = MeetingStore.defaultFileName) {
        fileURL = directory.appendingPathComponent(filename)
    }

    /// Persist the matched event, overwriting any prior one. Atomic: the new
    /// bytes land in place or not at all. ISO 8601 dates keep the file readable.
    public func save(_ meeting: MeetingEvent) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(meeting).write(to: fileURL, options: .atomic)
    }

    /// The saved event, or `nil` when none was written or the file is unreadable
    /// — a missing or corrupt document degrades to an untitled session, never an
    /// error.
    public func load() -> MeetingEvent? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MeetingEvent.self, from: data)
    }
}
