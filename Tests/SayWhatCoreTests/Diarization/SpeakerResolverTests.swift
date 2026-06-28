import Foundation
import Testing
@testable import SayWhatCore

@Suite("SpeakerResolver")
struct SpeakerResolverTests {
    /// An enrolled person with a single exemplar embedding.
    private func enrolled(_ name: String, _ embedding: [Float]) -> EnrolledPerson {
        let person = Person(name: name)
        return EnrolledPerson(
            person: person,
            exemplars: [Voiceprint(personID: person.id, embedding: embedding)]
        )
    }

    @Test("a slot matching an enrolled person resolves to them, minting nothing")
    func matchesEnrolled() {
        let eric = enrolled("Eric", [1, 0])
        let resolution = SpeakerResolver().resolve([0: [0.9, 0.1]], against: [eric])

        let resolved = resolution.bySlot[0]
        #expect(resolved?.person == eric.person)
        #expect(resolved?.name == "Eric")
        // The slot's own embedding is carried as an exemplar bound to the person.
        #expect(resolved?.exemplar.embedding == [0.9, 0.1])
        #expect(resolved?.exemplar.personID == eric.person.id)
    }

    @Test("a slot matching nobody mints an un-named speaker carrying its embedding")
    func mintsNewSpeaker() {
        let eric = enrolled("Eric", [1, 0])
        let resolution = SpeakerResolver().resolve([0: [0, 1]], against: [eric])

        let resolved = resolution.bySlot[0]
        #expect(resolved?.person == nil)
        #expect(resolved?.name == "Speaker 1")
        #expect(resolved?.exemplar.embedding == [0, 1])
        // An un-named mint is un-owned — never persisted until the user names it.
        #expect(resolved?.exemplar.personID == nil)
    }

    @Test("an empty directory mints one speaker per slot, in slot order")
    func emptyDirectoryMintsAll() {
        let resolution = SpeakerResolver().resolve(
            [1: [0, 1], 0: [1, 0]],
            against: []
        )

        #expect(resolution.bySlot[0]?.name == "Speaker 1")
        #expect(resolution.bySlot[1]?.name == "Speaker 2")
        #expect(resolution.bySlot[0]?.exemplar.embedding == [1, 0])
        #expect(resolution.bySlot[1]?.exemplar.embedding == [0, 1])
    }

    @Test("two slots resolve to their respective enrolled persons, not crossed")
    func distinctSlotsDistinctSpeakers() {
        let eric = enrolled("Eric", [1, 0])
        let ashley = enrolled("Ashley", [0, 1])
        let resolution = SpeakerResolver().resolve(
            [0: [0.1, 0.9], 1: [0.9, 0.1]],
            against: [eric, ashley]
        )

        #expect(resolution.bySlot[0]?.person == ashley.person)
        #expect(resolution.bySlot[1]?.person == eric.person)
    }

    @Test("when two slots both match one person, the stronger keeps them; the other mints")
    func mutualExclusion() {
        let eric = enrolled("Eric", [1, 0])
        // Slot 0 is a perfect match; slot 1 also clears threshold but is weaker.
        let resolution = SpeakerResolver().resolve(
            [0: [1, 0], 1: [0.9, 0.1]],
            against: [eric]
        )

        #expect(resolution.bySlot[0]?.person == eric.person)
        // The newcomer takes the first free number; "Eric" isn't a "Speaker N".
        #expect(resolution.bySlot[1]?.person == nil)
        #expect(resolution.bySlot[1]?.name == "Speaker 1")
    }

    @Test("a newcomer skips numbers already taken by enrolled Speaker N names")
    func mintsUniqueAgainstExistingSpeakers() {
        // The directory already has persons literally named "Speaker N".
        let existing = [enrolled("Speaker 1", [1, 0]), enrolled("Speaker 3", [0, 1])]
        // [-1, -1] is dissimilar to both axes, so it matches nobody and mints.
        let resolution = SpeakerResolver().resolve([0: [-1, -1]], against: existing)

        // Smallest free number, not a duplicate "Speaker 1".
        #expect(resolution.bySlot[0]?.name == "Speaker 2")
    }

    @Test("ties pick the earlier directory entry, deterministically")
    func tieBreakByDirectoryOrder() {
        let first = enrolled("First", [1, 0])
        let second = enrolled("Second", [1, 0])
        let resolution = SpeakerResolver().resolve([0: [1, 0]], against: [first, second])

        #expect(resolution.bySlot[0]?.person == first.person)
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
        let resolution = SpeakerResolver().resolve([:], against: [enrolled("Eric", [1, 0])])
        #expect(resolution.bySlot.isEmpty)
    }
}
