import Foundation
import Testing
@testable import SayWhatCore

/// A model-free ``SpeakerEmbedder`` that derives a vector from a clip's fill
/// value, so a test can tag a slot's frames and predict which voiceprint they
/// match: a clip of all-`1`s embeds as `[1, 0]`, anything else as `[0, 1]`.
private struct MappedEmbedder: SpeakerEmbedder {
    func embedding(for samples: [Float]) async throws -> [Float]? {
        guard let value = samples.first else { return nil }
        return value == 1 ? [1, 0] : [0, 1]
    }
}

@Suite("LiveSpeakerNamer")
struct LiveSpeakerNamerTests {
    /// One second of constant-valued system audio starting at `second`.
    private func frame(at second: Int, value: Float) -> AudioFrame {
        AudioFrame(
            source: .system,
            startOffset: .seconds(second),
            samples: [Float](repeating: value, count: 16000)
        )
    }

    private func turn(_ slot: Int, _ from: Int, _ to: Int) -> SpeakerTurn {
        SpeakerTurn(speaker: slot, range: .seconds(from) ..< .seconds(to))
    }

    private func makeStore(_ voiceprints: [Voiceprint]) throws -> VoiceprintStore {
        let store = try VoiceprintStore()
        for voiceprint in voiceprints {
            try store.save(voiceprint)
        }
        return store
    }

    @Test("names a slot once it matches an enrolled voiceprint")
    func namesMatchedSlot() async throws {
        let store = try makeStore([Voiceprint(name: "Eric", embedding: [1, 0])])
        let namer = LiveSpeakerNamer(
            embedder: MappedEmbedder(),
            store: store,
            minSpeech: .seconds(1)
        )

        await namer.ingest(frame(at: 0, value: 1))
        await namer.update(SpeakerTimeline(turns: [turn(0, 0, 1)]))

        #expect(await namer.resolve() == [0: "Eric"])
    }

    @Test("an unknown voice stays unnamed and nothing is persisted")
    func unknownVoiceStaysGeneric() async throws {
        let store = try makeStore([Voiceprint(name: "Eric", embedding: [1, 0])])
        let namer = LiveSpeakerNamer(
            embedder: MappedEmbedder(),
            store: store,
            minSpeech: .seconds(1)
        )

        // Value 2 → [0, 1], which matches neither enrolled voice.
        await namer.ingest(frame(at: 0, value: 2))
        await namer.update(SpeakerTimeline(turns: [turn(0, 0, 1)]))

        #expect(await namer.resolve().isEmpty)
        // Read-only: the directory is untouched (minting is the final pass's job).
        #expect(try store.all().map(\.name) == ["Eric"])
    }

    @Test("a slot with too little audio is not named")
    func shortSlotNotNamed() async throws {
        let store = try makeStore([Voiceprint(name: "Eric", embedding: [1, 0])])
        // Needs 3s; only 1s is fed.
        let namer = LiveSpeakerNamer(
            embedder: MappedEmbedder(),
            store: store,
            minSpeech: .seconds(3)
        )

        await namer.ingest(frame(at: 0, value: 1))
        await namer.update(SpeakerTimeline(turns: [turn(0, 0, 1)]))

        #expect(await namer.resolve().isEmpty)
    }

    @Test("a name sticks even if later audio would match someone else")
    func nameIsSticky() async throws {
        let store = try makeStore([Voiceprint(name: "Eric", embedding: [1, 0])])
        let namer = LiveSpeakerNamer(
            embedder: MappedEmbedder(),
            store: store,
            minSpeech: .seconds(1)
        )

        await namer.ingest(frame(at: 0, value: 1))
        await namer.update(SpeakerTimeline(turns: [turn(0, 0, 1)]))
        #expect(await namer.resolve() == [0: "Eric"])

        // Enroll Bob and feed slot 0 audio that now embeds as Bob's vector; the
        // already-resolved slot must not flip.
        try store.save(Voiceprint(name: "Bob", embedding: [0, 1]))
        await namer.ingest(frame(at: 1, value: 2))
        await namer.update(SpeakerTimeline(turns: [turn(0, 0, 2)]))

        #expect(await namer.resolve() == [0: "Eric"])
    }

    @Test("with no store, nothing is named")
    func noStoreNoNames() async {
        let namer = LiveSpeakerNamer(embedder: MappedEmbedder(), store: nil, minSpeech: .seconds(1))

        await namer.ingest(frame(at: 0, value: 1))
        await namer.update(SpeakerTimeline(turns: [turn(0, 0, 1)]))

        #expect(await namer.resolve().isEmpty)
    }

    @Test("audio older than the window is dropped")
    func windowTrims() async throws {
        let store = try makeStore([Voiceprint(name: "Eric", embedding: [1, 0])])
        let namer = LiveSpeakerNamer(
            embedder: MappedEmbedder(),
            store: store,
            minSpeech: .seconds(1),
            window: .seconds(2)
        )

        // Eric speaks at 0..1, then 4s of someone else pushes that past the 2s
        // window — Eric's audio is gone, so his slot can no longer be named.
        await namer.ingest(frame(at: 0, value: 1))
        for second in 1 ... 4 {
            await namer.ingest(frame(at: second, value: 2))
        }
        await namer.update(SpeakerTimeline(turns: [turn(0, 0, 1)]))

        #expect(await namer.resolve().isEmpty)
    }
}
