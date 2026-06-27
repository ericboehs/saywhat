import Foundation
import Testing
@testable import SayWhatCore

/// A model-free ``Diarizer`` that records how many frames it saw and emits one
/// canned timeline, so ``HybridDiarizer``'s orchestration can be checked without
/// real engines.
private actor RecordingDiarizer: Diarizer {
    let timeline: SpeakerTimeline
    private(set) var framesSeen = 0

    init(_ timeline: SpeakerTimeline) {
        self.timeline = timeline
    }

    func diarize(_ frames: AsyncStream<AudioFrame>) async throws -> AsyncStream<SpeakerTimeline> {
        for await _ in frames {
            framesSeen += 1
        }
        let timeline = timeline
        return AsyncStream { continuation in
            continuation.yield(timeline)
            continuation.finish()
        }
    }
}

@Suite("HybridDiarizer")
struct HybridDiarizerTests {
    private func turn(_ speaker: Int, _ start: Double, _ end: Double) -> SpeakerTurn {
        SpeakerTurn(speaker: speaker, range: .seconds(start) ..< .seconds(end))
    }

    private func frames(_ count: Int) -> AsyncStream<AudioFrame> {
        AsyncStream { continuation in
            for index in 0 ..< count {
                continuation.yield(AudioFrame(
                    source: .system,
                    startOffset: .seconds(index),
                    samples: [0]
                ))
            }
            continuation.finish()
        }
    }

    @Test("emits the fused timeline: turns from one engine, embeddings from the other")
    func fusesBothEngines() async throws {
        let turns = SpeakerTimeline(turns: [turn(0, 0, 2), turn(1, 2, 4)])
        let embeddingSource = SpeakerTimeline(
            turns: [turn(5, 0, 2), turn(6, 2, 4)],
            embeddings: [5: [1, 0], 6: [0, 1]]
        )
        let hybrid = HybridDiarizer(
            turns: RecordingDiarizer(turns),
            embeddings: RecordingDiarizer(embeddingSource)
        )

        var last = SpeakerTimeline()
        for await snapshot in try await hybrid.diarize(frames(3)) {
            last = snapshot
        }

        #expect(last.turns == turns.turns)
        #expect(last.embeddings == [0: [1, 0], 1: [0, 1]])
    }

    @Test("replays every buffered frame to both sub-diarizers")
    func feedsBothEngines() async throws {
        let turnsEngine = RecordingDiarizer(SpeakerTimeline(turns: [turn(0, 0, 1)]))
        let embeddingEngine = RecordingDiarizer(SpeakerTimeline())
        let hybrid = HybridDiarizer(turns: turnsEngine, embeddings: embeddingEngine)

        for await _ in try await hybrid.diarize(frames(4)) {}

        #expect(await turnsEngine.framesSeen == 4)
        #expect(await embeddingEngine.framesSeen == 4)
    }
}
