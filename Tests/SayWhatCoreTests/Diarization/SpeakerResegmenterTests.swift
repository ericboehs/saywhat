import Foundation
import Testing
@testable import SayWhatCore

@Suite("SpeakerResegmenter")
struct SpeakerResegmenterTests {
    private func turn(_ slot: Int, _ from: Int, _ to: Int) -> SpeakerTurn {
        SpeakerTurn(speaker: slot, range: .seconds(from) ..< .seconds(to))
    }

    /// An enrolled person with a single exemplar embedding.
    private func enrolled(_ name: String, _ embedding: [Float]) -> EnrolledPerson {
        let person = Person(name: name)
        return EnrolledPerson(
            person: person,
            exemplars: [Voiceprint(personID: person.id, embedding: embedding)]
        )
    }

    /// The identity-group label assigned to each turn, in turn order.
    private func groups(_ result: SpeakerResegmenter.Resegmentation) -> [Int] {
        result.timeline.turns.map(\.speaker)
    }

    @Test("two dissimilar turns of one diarizer slot split into two voice groups")
    func splitsMergedSlot() {
        // Sortformer fused both into slot 0; their embeddings point at opposite
        // axes, so identity must pull them back apart.
        let turns = [turn(0, 0, 2), turn(0, 2, 4)]
        let result = SpeakerResegmenter().resegment(
            turns: turns,
            embeddings: [0: [1, 0], 1: [0, 1]],
            against: []
        )

        #expect(groups(result) == [0, 1])
        #expect(result.speakers[0]?.name == "Speaker 1")
        #expect(result.speakers[1]?.name == "Speaker 2")
    }

    @Test("two similar turns stay one group")
    func keepsOneVoiceTogether() {
        let turns = [turn(0, 0, 2), turn(1, 2, 4)]
        // Same voice (near-identical vectors) split across two diarizer slots.
        let result = SpeakerResegmenter().resegment(
            turns: turns,
            embeddings: [0: [1, 0], 1: [0.99, 0.01]],
            against: []
        )

        #expect(groups(result) == [0, 0])
        #expect(result.speakers.count == 1)
    }

    @Test("a sub-floor turn attaches to the temporally nearest group, ignoring its slot")
    func shortTurnAttachesByTime() {
        // The real-recording lesson: a short turn must follow *time*, not the
        // diarizer's slot. Turn 1 is unembeddable and shares slot 0 with turn 0
        // (far away at 0–2s), but sits right next to turn 2 (a different slot) at
        // 18–20s — so it must join turn 2's group, not turn 0's.
        let turns = [turn(0, 0, 2), turn(0, 20, 21), turn(9, 18, 20)]
        let result = SpeakerResegmenter().resegment(
            turns: turns,
            embeddings: [0: [1, 0], 2: [0, 1]],
            against: []
        )

        // Groups by first appearance: turn 0 → group 0, turn 2 (starts 18s) →
        // group 1. The short turn 1 joins group 1, its temporal neighbor.
        #expect(groups(result) == [0, 1, 1])
    }

    @Test("groups resolve to enrolled persons, splitting a slot that matches one of them")
    func resolvesSplitGroupsToPersons() {
        // The Theo+MKBHD failure in miniature: slot 0 holds a Theo turn then an
        // MKBHD turn. Theo is enrolled, MKBHD is not.
        let theo = enrolled("Theo", [1, 0])
        let turns = [turn(0, 0, 3), turn(0, 3, 6)]
        let result = SpeakerResegmenter().resegment(
            turns: turns,
            embeddings: [0: [0.98, 0.02], 1: [0, 1]],
            against: [theo]
        )

        #expect(groups(result) == [0, 1])
        #expect(result.speakers[0]?.person == theo.person)
        #expect(result.speakers[0]?.name == "Theo")
        #expect(result.speakers[1]?.person == nil)
        #expect(result.speakers[1]?.name == "Speaker 1")
    }

    @Test("an enrolled voice stays one group even when its turns are noisy")
    func enrolledVoiceStaysOneGroup() {
        // The Zwag-fragmentation fix: both turns clearly match Eric (0.7 and 0.6
        // cosine against his exemplar), but they sit ~100° apart from *each other*
        // (cosine ≈ −0.15), below the clustering threshold. Pure turn-to-turn
        // clustering would split them into two groups; anchoring on the enrolled
        // exemplar keeps them one — they are both Eric.
        let eric = enrolled("Eric", [1, 0])
        let turns = [turn(0, 0, 2), turn(1, 2, 4)]
        let result = SpeakerResegmenter().resegment(
            turns: turns,
            embeddings: [0: [0.7, -0.714], 1: [0.6, 0.8]],
            against: [eric]
        )

        #expect(groups(result) == [0, 0])
        #expect(result.speakers.count == 1)
        #expect(result.speakers[0]?.person == eric.person)
        #expect(result.speakers[0]?.name == "Eric")
    }

    @Test("unknown turns still cluster among themselves, separate from a known voice")
    func unknownTurnsClusterApartFromKnown() {
        // One turn matches enrolled Eric; two unmatched turns are similar to each
        // other but not to Eric, so they cluster into a single minted speaker — the
        // known voice and the unknown voice stay distinct.
        let eric = enrolled("Eric", [1, 0])
        let turns = [turn(0, 0, 2), turn(0, 2, 4), turn(1, 4, 6)]
        let result = SpeakerResegmenter().resegment(
            turns: turns,
            embeddings: [0: [1, 0], 1: [0, 1], 2: [0.02, 0.99]],
            against: [eric]
        )

        // Turn 0 → Eric (group 0); turns 1 & 2 cluster → one mint (group 1).
        #expect(groups(result) == [0, 1, 1])
        #expect(result.speakers[0]?.name == "Eric")
        #expect(result.speakers[1]?.person == nil)
        #expect(result.speakers[1]?.name == "Speaker 1")
    }

    @Test("an unmatched group carries an un-owned exemplar — nothing to persist")
    func unmatchedGroupIsUnowned() {
        let eric = enrolled("Eric", [1, 0])
        let result = SpeakerResegmenter().resegment(
            turns: [turn(0, 0, 2)],
            embeddings: [0: [0, 1]],
            against: [eric]
        )

        let resolved = result.speakers[0]
        #expect(resolved?.person == nil)
        #expect(resolved?.exemplar.personID == nil)
        #expect(resolved?.exemplar.embedding == [0, 1])
    }

    @Test("with nothing embeddable, the diarizer's own segmentation passes through")
    func noEmbeddingsPassThrough() {
        let turns = [turn(3, 0, 2), turn(5, 2, 4)]
        let result = SpeakerResegmenter().resegment(
            turns: turns,
            embeddings: [:],
            against: [enrolled("Eric", [1, 0])]
        )

        // Slots untouched, no identities resolved.
        #expect(groups(result) == [3, 5])
        #expect(result.speakers.isEmpty)
    }

    @Test("group ids follow the order voices first appear")
    func groupIdsFollowReadingOrder() {
        // The later-starting voice (turn 0, slot 9) and the earlier one (turn 1,
        // slot 2) — group 0 must be the one that speaks first in time.
        let turns = [turn(9, 5, 8), turn(2, 0, 3)]
        let result = SpeakerResegmenter().resegment(
            turns: turns,
            embeddings: [0: [1, 0], 1: [0, 1]],
            against: []
        )

        // Turn 1 starts at 0s, turn 0 at 5s → turn 1's voice is group 0.
        #expect(groups(result) == [1, 0])
    }

    @Test("many interleaved turns of three voices cluster into exactly three groups")
    func clustersManyTurnsIntoThreeVoices() {
        // Three voices on near-orthogonal axes, nine turns interleaved A,B,C,…, all
        // fused into one diarizer slot. Exercises the incremental (Lance-Williams)
        // average-linkage path over several merges — the result must be the same
        // three groups, numbered by first appearance, as re-averaging every pair.
        let axes: [[Float]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        let turns = (0 ..< 9).map { turn(0, $0, $0 + 1) }
        // Each turn's embedding sits on its voice's axis with a little jitter, so no
        // two turns of one voice are identical (the noisy-short-turn reality).
        let embeddings = Dictionary(uniqueKeysWithValues: (0 ..< 9).map { index -> (Int, [Float]) in
            var vector = axes[index % 3]
            vector[(index / 3) % 3] += 0.02
            return (index, vector)
        })
        let result = SpeakerResegmenter().resegment(
            turns: turns,
            embeddings: embeddings,
            against: []
        )

        // Voice A speaks first (turn 0) → group 0, B (turn 1) → 1, C (turn 2) → 2.
        #expect(groups(result) == [0, 1, 2, 0, 1, 2, 0, 1, 2])
        #expect(result.speakers.count == 3)
    }
}
