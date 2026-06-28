import Foundation
import Testing
@testable import SayWhatCore

@Suite("SpeakerAudio")
struct SpeakerAudioTests {
    /// One second of constant-valued samples at the model rate, tagged with its
    /// start so a slot's turns can select it.
    private func frame(at second: Int, value: Float) -> AudioFrame {
        AudioFrame(
            source: .system,
            startOffset: .seconds(second),
            samples: [Float](repeating: value, count: 16000)
        )
    }

    @Test("gathers every frame overlapping the slot's turns, in order")
    func gathersOverlappingFrames() {
        let frames = [frame(at: 0, value: 1), frame(at: 1, value: 2), frame(at: 2, value: 3)]
        // Slot 0 speaks across the first 1.5s — overlapping frames 0 and 1.
        let timeline = SpeakerTimeline(turns: [
            SpeakerTurn(speaker: 0, range: .seconds(0) ..< .seconds(1.5)),
            SpeakerTurn(speaker: 1, range: .seconds(2) ..< .seconds(3)),
        ])

        let slot0 = SpeakerAudio.samples(forSlot: 0, in: timeline, from: frames)
        #expect(slot0.count == 32000)
        #expect(slot0.first == 1)
        #expect(slot0.last == 2)

        let slot1 = SpeakerAudio.samples(forSlot: 1, in: timeline, from: frames)
        #expect(slot1.count == 16000)
        #expect(slot1.allSatisfy { $0 == 3 })
    }

    @Test("a slot with no turns gathers nothing")
    func noTurnsNoSamples() {
        let frames = [frame(at: 0, value: 1)]
        let timeline = SpeakerTimeline(turns: [
            SpeakerTurn(speaker: 0, range: .seconds(0) ..< .seconds(1)),
        ])

        #expect(SpeakerAudio.samples(forSlot: 9, in: timeline, from: frames).isEmpty)
    }

    @Test("a turn past the recorded audio gathers nothing")
    func turnBeyondAudio() {
        let frames = [frame(at: 0, value: 1)]
        let timeline = SpeakerTimeline(turns: [
            SpeakerTurn(speaker: 0, range: .seconds(5) ..< .seconds(6)),
        ])

        #expect(SpeakerAudio.samples(forSlot: 0, in: timeline, from: frames).isEmpty)
    }
}
