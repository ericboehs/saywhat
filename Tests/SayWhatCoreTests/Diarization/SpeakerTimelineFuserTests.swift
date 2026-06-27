import Foundation
import Testing
@testable import SayWhatCore

@Suite("SpeakerTimelineFuser")
struct SpeakerTimelineFuserTests {
    private func turn(_ speaker: Int, _ start: Double, _ end: Double) -> SpeakerTurn {
        SpeakerTurn(speaker: speaker, range: .seconds(start) ..< .seconds(end))
    }

    @Test("keeps the turns timeline and maps each slot's embedding by time overlap")
    func mapsByOverlap() {
        // Sortformer split three speakers; pyannote (here) also found three, over
        // matching windows. Each Sortformer slot should inherit the embedding of
        // the pyannote cluster it overlaps.
        let turns = SpeakerTimeline(turns: [
            turn(0, 0, 2),
            turn(1, 2, 4),
            turn(2, 4, 6),
        ])
        let embeddingSource = SpeakerTimeline(
            turns: [turn(7, 0, 2), turn(8, 2, 4), turn(9, 4, 6)],
            embeddings: [7: [1, 0], 8: [0, 1], 9: [1, 1]]
        )
        let fused = SpeakerTimelineFuser().fuse(turns: turns, embeddingSource: embeddingSource)

        #expect(fused.turns == turns.turns)
        #expect(fused.embeddings == [0: [1, 0], 1: [0, 1], 2: [1, 1]])
    }

    @Test("with no embeddings the turns pass through unchanged")
    func noEmbeddings() {
        let turns = SpeakerTimeline(turns: [turn(0, 0, 2), turn(1, 2, 4)])
        let fused = SpeakerTimelineFuser().fuse(turns: turns, embeddingSource: SpeakerTimeline())

        #expect(fused.turns == turns.turns)
        #expect(fused.embeddings.isEmpty)
    }

    @Test("a slot picks the embedding cluster it overlaps most when it spans several")
    func picksDominantOverlap() {
        // Slot 0 runs 0–10s; it overlaps cluster 8 for 1s but cluster 9 for 8s.
        let turns = SpeakerTimeline(turns: [turn(0, 0, 10)])
        let embeddingSource = SpeakerTimeline(
            turns: [turn(8, 0, 1), turn(9, 2, 10)],
            embeddings: [8: [1, 0], 9: [0, 1]]
        )
        let fused = SpeakerTimelineFuser().fuse(turns: turns, embeddingSource: embeddingSource)

        #expect(fused.embeddings == [0: [0, 1]])
    }

    @Test("when pyannote under-clusters, several turns slots share one embedding")
    func underClusteringCollapsesIdentity() {
        // Pyannote glued everyone into one cluster (7); both Sortformer slots map
        // onto it — strictly better than the whole track collapsing to one slot.
        let turns = SpeakerTimeline(turns: [turn(0, 0, 3), turn(1, 3, 6)])
        let embeddingSource = SpeakerTimeline(
            turns: [turn(7, 0, 6)],
            embeddings: [7: [1, 0]]
        )
        let fused = SpeakerTimelineFuser().fuse(turns: turns, embeddingSource: embeddingSource)

        #expect(fused.turns == turns.turns)
        #expect(fused.embeddings == [0: [1, 0], 1: [1, 0]])
    }

    @Test("a turns slot overlapping no embedded cluster is left unembedded")
    func slotWithoutOverlapHasNoEmbedding() {
        let turns = SpeakerTimeline(turns: [turn(0, 0, 2), turn(1, 10, 12)])
        let embeddingSource = SpeakerTimeline(
            turns: [turn(7, 0, 2)],
            embeddings: [7: [1, 0]]
        )
        let fused = SpeakerTimelineFuser().fuse(turns: turns, embeddingSource: embeddingSource)

        #expect(fused.embeddings == [0: [1, 0]])
    }
}
