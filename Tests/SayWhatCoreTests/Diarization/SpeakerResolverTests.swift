import Foundation
import Testing
@testable import SayWhatCore

@Suite("SpeakerResolver")
struct SpeakerResolverTests {
    private func voiceprint(_ name: String, _ embedding: [Float]) -> Voiceprint {
        Voiceprint(name: name, embedding: embedding)
    }

    @Test("a slot matching an enrolled speaker resolves to them, minting nothing")
    func matchesEnrolled() {
        let eric = voiceprint("Eric", [1, 0])
        let resolution = SpeakerResolver().resolve([0: [0.9, 0.1]], against: [eric])

        #expect(resolution.bySlot[0] == eric)
        #expect(resolution.minted.isEmpty)
    }

    @Test("a slot matching nobody mints a new voiceprint carrying its embedding")
    func mintsNewSpeaker() {
        let eric = voiceprint("Eric", [1, 0])
        let resolution = SpeakerResolver().resolve([0: [0, 1]], against: [eric])

        let minted = try? #require(resolution.minted.first)
        #expect(resolution.minted.count == 1)
        #expect(minted?.name == "Speaker 1")
        #expect(minted?.embedding == [0, 1])
        #expect(resolution.bySlot[0] == minted)
    }

    @Test("an empty directory mints one voiceprint per slot, in slot order")
    func emptyDirectoryMintsAll() {
        let resolution = SpeakerResolver().resolve(
            [1: [0, 1], 0: [1, 0]],
            against: []
        )

        #expect(resolution.minted.map(\.name) == ["Speaker 1", "Speaker 2"])
        #expect(resolution.bySlot[0]?.embedding == [1, 0])
        #expect(resolution.bySlot[1]?.embedding == [0, 1])
    }

    @Test("two slots resolve to their respective enrolled speakers, not crossed")
    func distinctSlotsDistinctSpeakers() {
        let eric = voiceprint("Eric", [1, 0])
        let ashley = voiceprint("Ashley", [0, 1])
        let resolution = SpeakerResolver().resolve(
            [0: [0.1, 0.9], 1: [0.9, 0.1]],
            against: [eric, ashley]
        )

        #expect(resolution.bySlot[0] == ashley)
        #expect(resolution.bySlot[1] == eric)
        #expect(resolution.minted.isEmpty)
    }

    @Test("when two slots both match one speaker, the stronger keeps them; the other mints")
    func mutualExclusion() {
        let eric = voiceprint("Eric", [1, 0])
        // Slot 0 is a perfect match; slot 1 also clears threshold but is weaker.
        let resolution = SpeakerResolver().resolve(
            [0: [1, 0], 1: [0.9, 0.1]],
            against: [eric]
        )

        #expect(resolution.bySlot[0] == eric)
        // The newcomer takes the first free number; "Eric" isn't a "Speaker N".
        #expect(resolution.bySlot[1]?.name == "Speaker 1")
        #expect(resolution.minted.map(\.name) == ["Speaker 1"])
    }

    @Test("a newcomer skips numbers already taken by enrolled Speaker N names")
    func mintsUniqueAgainstExistingSpeakers() {
        // The directory already has auto-named speakers from prior meetings.
        let existing = [voiceprint("Speaker 1", [1, 0]), voiceprint("Speaker 3", [0, 1])]
        // [-1, -1] is dissimilar to both axes, so it matches nobody and mints.
        let resolution = SpeakerResolver().resolve([0: [-1, -1]], against: existing)

        // Smallest free number, not a duplicate "Speaker 1".
        #expect(resolution.minted.map(\.name) == ["Speaker 2"])
    }

    @Test("ties pick the earlier directory entry, deterministically")
    func tieBreakByDirectoryOrder() {
        let first = voiceprint("First", [1, 0])
        let second = voiceprint("Second", [1, 0])
        let resolution = SpeakerResolver().resolve([0: [1, 0]], against: [first, second])

        #expect(resolution.bySlot[0] == first)
    }

    @Test("the mint name is customizable")
    func customMintName() {
        let resolution = SpeakerResolver().resolve(
            [2: [1, 0]],
            against: [],
            mintName: { "Guest \($0)" }
        )

        // The closure receives the directory-unique number (first free is 1).
        #expect(resolution.bySlot[2]?.name == "Guest 1")
    }

    @Test("no observations resolve to nothing")
    func empty() {
        let resolution = SpeakerResolver().resolve([:], against: [voiceprint("Eric", [1, 0])])
        #expect(resolution.bySlot.isEmpty)
        #expect(resolution.minted.isEmpty)
    }
}
