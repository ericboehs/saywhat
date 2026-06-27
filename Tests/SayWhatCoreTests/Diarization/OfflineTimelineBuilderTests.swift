import Foundation
import Testing
@testable import SayWhatCore

@Suite("OfflineTimelineBuilder")
struct OfflineTimelineBuilderTests {
    private func segment(_ id: String, from start: Double, to end: Double) -> RawSpeakerSegment {
        RawSpeakerSegment(speakerId: id, range: .seconds(start) ..< .seconds(end))
    }

    private let builder = OfflineTimelineBuilder()

    @Test("assigns integer slots in first-talk order")
    func slotsByFirstTalk() {
        // "bravo" speaks first in time, so it gets slot 0 regardless of input order.
        let result = builder.timeline(from: [
            segment("alpha", from: 2, to: 3),
            segment("bravo", from: 0, to: 1),
            segment("alpha", from: 4, to: 5),
        ])

        #expect(result.turns.map(\.speaker) == [0, 1, 1])
        #expect(result.turns.map(\.range.lowerBound) == [.seconds(0), .seconds(2), .seconds(4)])
    }

    @Test("a stable id keeps the same slot across turns")
    func stableIdStableSlot() {
        let result = builder.timeline(from: [
            segment("x", from: 0, to: 1),
            segment("y", from: 1, to: 2),
            segment("x", from: 2, to: 3),
        ])
        #expect(result.turns.map(\.speaker) == [0, 1, 0])
    }

    @Test("drops empty spans")
    func dropsDegenerate() {
        let result = builder.timeline(from: [
            segment("a", from: 1, to: 1), // empty
            segment("c", from: 0, to: 1), // kept
        ])
        #expect(result.turns.count == 1)
        #expect(result.turns.first?.speaker == 0)
        #expect(result.turns.first?.range == .seconds(0) ..< .seconds(1))
    }

    @Test("an empty input yields an empty timeline")
    func empty() {
        #expect(builder.timeline(from: []).turns.isEmpty)
    }

    @Test("the result resolves a dominant speaker over a query window")
    func feedsDominantSpeaker() {
        let result = builder.timeline(from: [
            segment("a", from: 0, to: 2),
            segment("b", from: 2, to: 5),
        ])
        // 1.5–4.5 s overlaps b for 2.5 s vs a for 0.5 s.
        #expect(result.dominantSpeaker(in: .seconds(1.5) ..< .seconds(4.5)) == 1)
    }

    @Test("re-keys speaker-id embeddings onto their integer slots")
    func reKeysEmbeddings() {
        // "bravo" talks first → slot 0; "alpha" → slot 1.
        let result = builder.timeline(
            from: [
                segment("alpha", from: 2, to: 3),
                segment("bravo", from: 0, to: 1),
            ],
            speakerEmbeddings: ["alpha": [1, 0], "bravo": [0, 1]]
        )

        #expect(result.embeddings == [0: [0, 1], 1: [1, 0]])
    }

    @Test("a speaker with no embedding is simply omitted from the map")
    func partialEmbeddings() {
        let result = builder.timeline(
            from: [
                segment("a", from: 0, to: 1),
                segment("b", from: 1, to: 2),
            ],
            speakerEmbeddings: ["a": [1, 0]] // b has none
        )

        #expect(result.embeddings == [0: [1, 0]])
    }

    @Test("with no embeddings supplied the map is empty")
    func noEmbeddings() {
        let result = builder.timeline(from: [segment("a", from: 0, to: 1)])
        #expect(result.embeddings.isEmpty)
    }
}
