import Foundation
import Testing
@testable import SayWhatCore

/// Coalescing fuses consecutive same-speaker blocks into one — the invariant the
/// final pass establishes, re-applied after a rename or reassign leaves two
/// adjacent blocks the same speaker. Only genuinely adjacent runs merge.
@Suite("Transcript coalesce")
struct TranscriptCoalesceTests {
    private typealias Utterance = Transcript.Utterance

    private func utterance(
        _ id: Int,
        _ speaker: SpeakerLabel,
        name: String? = nil,
        text: String? = nil,
        words: [WordTiming] = []
    ) -> Utterance {
        Utterance(
            id: id,
            speaker: speaker,
            speakerName: name,
            text: text ?? "turn \(id)",
            range: .seconds(id) ..< .seconds(id + 1),
            words: words
        )
    }

    @Test("adjacent same-speaker blocks fuse: text joined, range spanned, first id kept")
    func fusesAdjacent() {
        let transcript = Transcript(utterances: [
            utterance(0, .remote(0), name: "Yone", text: "So anyway —"),
            utterance(1, .remote(0), name: "Yone", text: "as I was saying."),
        ])

        let merged = transcript.coalesced()

        #expect(merged.utterances.count == 1)
        #expect(merged.utterances[0].id == 0)
        #expect(merged.utterances[0].text == "So anyway — as I was saying.")
        #expect(merged.utterances[0].range == .seconds(0) ..< .seconds(2))
    }

    @Test("a different speaker between two same-speaker blocks blocks the merge")
    func keepsNonAdjacentSeparate() {
        let transcript = Transcript(utterances: [
            utterance(0, .remote(0), name: "Yone"),
            utterance(1, .remote(1), name: "Zwag"),
            utterance(2, .remote(0), name: "Yone"),
        ])

        let merged = transcript.coalesced()

        #expect(merged.utterances.map(\.id) == [0, 1, 2])
    }

    @Test("differing names on the same slot are not fused")
    func keepsDifferentNamesSeparate() {
        let transcript = Transcript(utterances: [
            utterance(0, .remote(0), name: "Speaker 1"),
            utterance(1, .remote(0), name: "MKBHD"),
        ])

        #expect(transcript.coalesced().utterances.count == 2)
    }

    @Test("word timings concatenate in order across the fused block")
    func concatenatesWords() {
        let first = WordTiming(text: "hello", range: .seconds(0) ..< .seconds(1))
        let second = WordTiming(text: "world", range: .seconds(1) ..< .seconds(2))
        let transcript = Transcript(utterances: [
            utterance(0, .remote(0), name: "Yone", words: [first]),
            utterance(1, .remote(0), name: "Yone", words: [second]),
        ])

        #expect(transcript.coalesced().utterances[0].words == [first, second])
    }

    @Test("an empty-text piece is skipped in the join, leaving no stray space")
    func skipsEmptyText() {
        let transcript = Transcript(utterances: [
            utterance(0, .remote(0), name: "Yone", text: "Done."),
            utterance(1, .remote(0), name: "Yone", text: ""),
        ])

        #expect(transcript.coalesced().utterances[0].text == "Done.")
    }

    @Test("renaming a slot to match its neighbor then coalescing fuses them")
    func renameThenCoalesceFuses() {
        let transcript = Transcript(utterances: [
            utterance(0, .remote(0), name: "Yone", text: "First."),
            utterance(1, .remote(1), name: "Speaker 2", text: "Second."),
        ])

        // Naming slot 1 "Yone" adopts slot 0's color, making the two adjacent and
        // same-speaker — coalescing then fuses them into one block.
        let merged = transcript.renamingSpeaker(1, to: "Yone").coalesced()

        #expect(merged.utterances.count == 1)
        #expect(merged.utterances[0].text == "First. Second.")
    }
}
