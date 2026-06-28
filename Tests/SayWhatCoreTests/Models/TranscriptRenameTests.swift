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

    @Test("naming a second slot the same merges it onto the first's color")
    func renamingTwoSlotsTheSameMergesColor() {
        // The diarizer split one person into slots 0 and 1; the user already named
        // slot 0 "Eric" and now names slot 1 "Eric" too.
        let transcript = Transcript(utterances: [
            utterance(0, .remote(0), name: "Eric"),
            utterance(1, .remote(1), name: "Speaker 2"),
            utterance(2, .remote(0), name: "Eric"),
            utterance(3, .remote(1), name: "Speaker 2"),
        ])

        let merged = transcript.renamingSpeaker(1, to: "Eric")

        // Every turn now reads "Eric" in slot 0's color — one speaker, one color.
        #expect(merged.utterances.map(\.speaker) == [
            .remote(0),
            .remote(0),
            .remote(0),
            .remote(0),
        ])
        #expect(merged.utterances.allSatisfy { $0.speakerName == "Eric" })
    }

    @Test("reassigning one utterance changes only it, leaving its group untouched")
    func reassignsSingleUtterance() {
        let transcript = Transcript(utterances: [
            utterance(0, .remote(0), name: "Speaker 1"),
            utterance(1, .remote(0), name: "Speaker 1"),
            utterance(2, .remote(0), name: "Speaker 1"),
        ])

        // The diarizer fused two voices into slot 0; correct just utterance 1.
        let fixed = transcript.reassigningUtterance(1, to: "MKBHD")

        #expect(fixed.utterances.map(\.speakerName) == ["Speaker 1", "MKBHD", "Speaker 1"])
        // A brand-new name keeps the segment's own color (still slot 0).
        #expect(fixed.utterances.map(\.speaker) == [.remote(0), .remote(0), .remote(0)])
        #expect(fixed.utterances.map(\.text) == transcript.utterances.map(\.text))
    }

    @Test("a reassigned segment adopts the color of that person elsewhere")
    func reassignAdoptsExistingPersonColor() {
        let transcript = Transcript(utterances: [
            utterance(0, .remote(0), name: "Speaker 1"),
            utterance(1, .remote(1), name: "Theo"),
            utterance(2, .remote(0), name: "Speaker 1"),
        ])

        // Utterance 2 is really Theo, who already shows as slot 1 — it recolors to
        // match, so Theo reads in one color throughout.
        let fixed = transcript.reassigningUtterance(2, to: "Theo")

        #expect(fixed.utterances.map(\.speaker) == [.remote(0), .remote(1), .remote(1)])
        #expect(fixed.utterances.map(\.speakerName) == ["Speaker 1", "Theo", "Theo"])
    }
}
