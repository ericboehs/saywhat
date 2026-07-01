import Foundation

/// The line-delimited JSON wire form of a finalized ``Transcript`` — one compact
/// JSON object per utterance, one utterance per line.
///
/// This is the *shared schema*, not a transport: the `saywhat` CLI emits it over a
/// recording so the pipeline can be exercised and diffed from the command line, and
/// the benchmark reads it back as either a hypothesis or a ground-truth reference.
/// The app may read/write the same format for export — but nothing shells out to the
/// CLI or watches these files at runtime; both are thin frontends over the same core
/// (the earl-scribe file-watching model was deliberately retired, see CLAUDE.md).
///
/// Times are plain `Double` seconds, not `Duration`'s native 128-bit attosecond
/// pair, so a line reads and diffs like `"start":12.88` rather than an opaque
/// `[0, 12880000000000000000]`. Keys are emitted sorted so two runs of the same
/// transcript produce byte-identical output, line by line — the property a golden
/// fixture and a `diff`-based regression check both rely on.
public enum TranscriptJSONL {
    /// One word and the span it was spoken over, in seconds.
    struct Word: Codable, Equatable {
        let text: String
        let start: Double
        let end: Double
    }

    /// One utterance: who, when, what, and (when the ASR provided them) word timings.
    struct Line: Codable, Equatable {
        let index: Int
        let speaker: String
        let name: String?
        let start: Double
        let end: Double
        let text: String
        let words: [Word]?
    }

    /// Encode `transcript` as newline-terminated JSONL: one ``Line`` per utterance,
    /// in order. Each line ends with `\n`, including the last, so the output appends
    /// and concatenates cleanly. An empty transcript yields the empty string.
    public static func encode(_ transcript: Transcript) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var out = ""
        for utterance in transcript.utterances {
            let line = Line(
                index: utterance.id,
                speaker: encode(utterance.speaker),
                name: utterance.speakerName,
                start: utterance.start.seconds,
                end: utterance.end.seconds,
                text: utterance.text,
                words: utterance.words.isEmpty ? nil : utterance.words.map {
                    Word(
                        text: $0.text,
                        start: $0.range.lowerBound.seconds,
                        end: $0.range.upperBound.seconds
                    )
                }
            )
            guard let data = try? encoder.encode(line), let json = String(
                data: data,
                encoding: .utf8
            ) else {
                continue
            }
            out += json + "\n"
        }
        return out
    }

    /// Parse JSONL back into a ``Transcript``. Blank lines are skipped; a malformed
    /// line throws. Utterances are returned in the file's order, preserving each
    /// line's `index` as the utterance id so cursors and references stay stable.
    public static func decode(_ text: String) throws -> Transcript {
        let decoder = JSONDecoder()
        var utterances: [Transcript.Utterance] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let line = try decoder.decode(Line.self, from: Data(trimmed.utf8))
            try utterances.append(Transcript.Utterance(
                id: line.index,
                speaker: decodeSpeaker(line.speaker),
                speakerName: line.name,
                text: line.text,
                range: .seconds(line.start) ..< .seconds(line.end),
                words: (line.words ?? []).map {
                    WordTiming(text: $0.text, range: .seconds($0.start) ..< .seconds($0.end))
                }
            ))
        }
        return Transcript(utterances: utterances)
    }

    /// `you` for the mic channel, `remote:N` for a diarizer slot — a stable, readable
    /// string round-tripped by ``decodeSpeaker(_:)``.
    private static func encode(_ speaker: SpeakerLabel) -> String {
        switch speaker {
        case .you: "you"
        case let .remote(slot): "remote:\(slot)"
        }
    }

    private static func decodeSpeaker(_ string: String) throws -> SpeakerLabel {
        if string == "you" { return .you }
        if string.hasPrefix("remote:"), let slot = Int(string.dropFirst("remote:".count)) {
            return .remote(slot)
        }
        throw DecodingError.dataCorrupted(.init(
            codingPath: [],
            debugDescription: "unrecognized speaker label \"\(string)\""
        ))
    }
}
