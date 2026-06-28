import Foundation

/// The full editable state of a finalized session's transcript, persisted as a
/// JSON document **beside its audio** in the session directory.
///
/// The authoritative ``Transcript`` is a derived record, but once the user starts
/// correcting speaker labels it becomes hand-curated and must survive reopening
/// the meeting — so it is saved as a document next to the recording (the same
/// place the audio already lives), not recomputed from scratch each time. It
/// carries everything an edit needs:
///
/// - `transcript` — the displayed record itself.
/// - `speakers` — how each identity **group** resolved, so a whole-speaker rename
///   can re-bind that group's exemplar after reopen.
/// - `utteranceVoiceprints` — each remote utterance's *own* voice vector, so a
///   single mis-grouped segment can be reassigned (and its voice bound to the
///   right person) even after reopen, when the group's exemplar is someone else's.
///
/// Strictly local — the file never leaves the machine (the on-device invariant).
public struct SessionTranscript: Sendable, Equatable, Codable {
    /// The schema version, so a future format change can migrate rather than fail.
    public var version: Int
    /// The displayed, possibly hand-corrected transcript.
    public var transcript: Transcript
    /// Identity group → how it resolved (matched person or un-named mint).
    public var speakers: [Int: ResolvedSpeaker]
    /// Utterance id → that segment's own voiceprint, for per-segment reassignment.
    /// Mic (`you`) utterances carry none.
    public var utteranceVoiceprints: [Int: Voiceprint]

    /// The current document schema version.
    public static let currentVersion = 1

    public init(
        version: Int = SessionTranscript.currentVersion,
        transcript: Transcript,
        speakers: [Int: ResolvedSpeaker] = [:],
        utteranceVoiceprints: [Int: Voiceprint] = [:]
    ) {
        self.version = version
        self.transcript = transcript
        self.speakers = speakers
        self.utteranceVoiceprints = utteranceVoiceprints
    }
}

/// Reads and writes a session's ``SessionTranscript`` as `transcript.json` in the
/// session directory.
///
/// Writes are **atomic** (write-then-rename), so a crash mid-save can never leave
/// a half-written document that loses the meeting's curated labels — the
/// audio-is-durable tenet, applied to its hand-edited derived record. Pure
/// Foundation I/O, unit-testable against a temp directory.
public struct TranscriptStore: Sendable {
    /// The document file within the session directory.
    public let fileURL: URL

    /// The document's default name — `transcript.json`, distinct from the live
    /// `transcript.md` append log. Used to detect reopenable sessions.
    public static let defaultFileName = "transcript.json"

    /// - Parameters:
    ///   - directory: the session directory the document is written into.
    ///   - filename: the document's name within it. Defaults to ``defaultFileName``.
    public init(directory: URL, filename: String = TranscriptStore.defaultFileName) {
        fileURL = directory.appendingPathComponent(filename)
    }

    /// Whether a saved document exists yet.
    public var exists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Persist `document`, overwriting any prior one. Atomic: the new bytes land
    /// in place or not at all.
    public func save(_ document: SessionTranscript) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(document).write(to: fileURL, options: .atomic)
    }

    /// Load the saved document, or `nil` when none has been written yet.
    public func load() throws -> SessionTranscript? {
        guard exists else { return nil }
        return try JSONDecoder().decode(SessionTranscript.self, from: Data(contentsOf: fileURL))
    }
}
