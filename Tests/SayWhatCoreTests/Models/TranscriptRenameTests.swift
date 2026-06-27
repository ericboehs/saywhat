import Foundation
import Testing
@testable import SayWhatCore

/// Renaming a speaker relabels exactly that speaker's turns and leaves everyone
/// else — including the same-numbered *live* slot of another speaker — untouched.
/// This is what lets the UI apply a just-chosen name across the whole transcript
/// without re-running the final pass.
@Suite("Transcript speaker rename")
struct TranscriptRenameTests {
    private typealias Utterance = Transcript.Utterance

    private func utterance(_ id: Int, _ speaker: SpeakerLabel, name: String? = nil) -> Utterance {
        Utterance(
            id: id,
            speaker: speaker,
            speakerName: name,
            text: "turn \(id)",
            range: .seconds(id) ..< .seconds(id + 1)
        )
    }

    @Test("renames every turn of the target slot and only that slot")
    func renamesOnlyTargetSlot() {
        let transcript = Transcript(utterances: [
            utterance(0, .you),
            utterance(1, .remote(0), name: "Speaker 1"),
            utterance(2, .remote(1), name: "Speaker 2"),
            utterance(3, .remote(0), name: "Speaker 1"),
        ])

        let renamed = transcript.renamingSpeaker(0, to: "Tom")

        #expect(renamed.utterances.map(\.speakerName) == [nil, "Tom", "Speaker 2", "Tom"])
        // Ids, speakers, and text are preserved — only the name changed.
        #expect(renamed.utterances.map(\.id) == transcript.utterances.map(\.id))
        #expect(renamed.utterances.map(\.speaker) == transcript.utterances.map(\.speaker))
        #expect(renamed.utterances.map(\.text) == transcript.utterances.map(\.text))
    }

    @Test("renaming an absent slot is a no-op")
    func renamingAbsentSlotChangesNothing() {
        let transcript = Transcript(utterances: [utterance(0, .remote(0), name: "Speaker 1")])
        #expect(transcript.renamingSpeaker(5, to: "Nobody") == transcript)
    }
}
