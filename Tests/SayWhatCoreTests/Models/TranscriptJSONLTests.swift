import Testing
@testable import SayWhatCore

@Suite("TranscriptJSONL")
struct TranscriptJSONLTests {
    /// A small two-speaker transcript with word timings on one turn and none on
    /// another — exercises both the `you`/`remote` labels and the optional words.
    private static func sample() -> Transcript {
        Transcript(utterances: [
            Transcript.Utterance(
                id: 0,
                speaker: .remote(0),
                speakerName: "Allison",
                text: "rock and a hard place",
                range: .seconds(0) ..< .seconds(9.06),
                words: [
                    WordTiming(text: "rock", range: .seconds(0) ..< .seconds(0.2)),
                    WordTiming(text: "place", range: .seconds(8.8) ..< .seconds(9.06)),
                ]
            ),
            Transcript.Utterance(
                id: 1,
                speaker: .you,
                text: "I can write that.",
                range: .seconds(51.0) ..< .seconds(53.5)
            ),
        ])
    }

    @Test("round-trips an utterance with speakers, names, ranges, and word timings")
    func roundTrips() throws {
        let original = Self.sample()
        let decoded = try TranscriptJSONL.decode(TranscriptJSONL.encode(original))
        #expect(decoded == original)
    }

    @Test("emits one newline-terminated line per utterance")
    func oneLinePerUtterance() {
        let jsonl = TranscriptJSONL.encode(Self.sample())
        let lines = jsonl.split(separator: "\n", omittingEmptySubsequences: false)
        // Two utterances plus the trailing empty element after the final newline.
        #expect(jsonl.hasSuffix("\n"))
        #expect(lines.count(where: { !$0.isEmpty }) == 2)
    }

    @Test("encodes times as readable second values, not the Duration attosecond pair")
    func readableSeconds() {
        let jsonl = TranscriptJSONL.encode(Self.sample())
        #expect(jsonl.contains("\"start\":0"))
        #expect(jsonl.contains("\"end\":9.06"))
        #expect(!jsonl.contains("000000000")) // no raw attosecond integers leaked
    }

    @Test("is deterministic — the same transcript encodes byte-identically")
    func deterministic() {
        #expect(TranscriptJSONL.encode(Self.sample()) == TranscriptJSONL.encode(Self.sample()))
    }

    @Test("an empty transcript encodes to the empty string and back")
    func empty() throws {
        #expect(TranscriptJSONL.encode(Transcript()).isEmpty)
        #expect(try TranscriptJSONL.decode("").utterances.isEmpty)
    }

    @Test("skips blank lines and preserves each line's index as the utterance id")
    func skipsBlankLinesKeepsIndex() throws {
        let jsonl = """
        {"end":9.06,"index":7,"name":"Allison","speaker":"remote:2","start":0,"text":"hi","words":null}

        {"end":53.5,"index":9,"name":null,"speaker":"you","start":51,"text":"bye","words":null}
        """
        let decoded = try TranscriptJSONL.decode(jsonl)
        #expect(decoded.utterances.map(\.id) == [7, 9])
        #expect(decoded.utterances[0].speaker == .remote(2))
        #expect(decoded.utterances[1].speaker == .you)
    }

    @Test("a malformed speaker label throws rather than guessing")
    func rejectsBadSpeaker() {
        let jsonl = #"{"end":1,"index":0,"name":null,"speaker":"nobody","start":0,"text":"x","words":null}"#
        #expect(throws: (any Error).self) {
            try TranscriptJSONL.decode(jsonl)
        }
    }
}
