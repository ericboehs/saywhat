import Foundation
import Testing
@testable import SayWhatCore

@Suite("AudioMixer")
struct AudioMixerTests {
    /// Drain a finished mixer's stream into a flat sample list plus per-frame metadata.
    private func collect(_ stream: AsyncStream<AudioFrame>) async -> [AudioFrame] {
        var frames: [AudioFrame] = []
        for await frame in stream {
            frames.append(frame)
        }
        return frames
    }

    @Test("emits one mixed frame per drained pair, then finishes when both tracks end")
    func mixesAndFinishes() async {
        let mixer = AudioMixer()
        let stream = await mixer.output()
        await mixer.feed(.microphone, [0.1, 0.2, 0.3]) // no system yet — nothing drains
        await mixer.feed(.system, [0.4, 0.5, 0.6]) // now 3 pairs are ready
        await mixer.finish(.microphone)
        await mixer.finish(.system) // both done + drained → stream finishes

        let frames = await collect(stream)
        #expect(frames.count == 1)
        #expect(frames[0].startOffset == .zero)
        #expect(frames[0].samples == [Float(0.1) + 0.4, Float(0.2) + 0.5, Float(0.3) + 0.6])
    }

    @Test("advances the frame offset by the samples already emitted")
    func offsetsAdvance() async {
        let mixer = AudioMixer()
        let stream = await mixer.output()
        await mixer.feed(.microphone, [0.1, 0.2, 0.3])
        await mixer.feed(.system, [0.4, 0.5, 0.6]) // frame 1: 3 samples at offset 0
        await mixer.feed(.microphone, [0.7, 0.8])
        await mixer.feed(.system, [0.9, 1.0]) // frame 2: 2 samples at offset 3/16k
        await mixer.finish(.microphone)
        await mixer.finish(.system)

        let frames = await collect(stream)
        #expect(frames.count == 2)
        #expect(frames[1].startOffset == .seconds(3.0 / 16000))
        #expect(frames[1].samples.count == 2)
    }

    @Test("flushes the surviving track once its counterpart finishes")
    func flushesTail() async {
        let mixer = AudioMixer()
        let stream = await mixer.output()
        await mixer.feed(.microphone, [0.1, 0.2, 0.3, 0.4])
        await mixer.feed(.system, [0.01, 0.02]) // 2 pairs drain
        await mixer.finish(.system) // mic 3,4 unpaired forever → flushed as-is
        await mixer.finish(.microphone)

        let frames = await collect(stream)
        let all = frames.flatMap(\.samples)
        #expect(all == [Float(0.1) + 0.01, Float(0.2) + 0.02, 0.3, 0.4])
    }

    @Test("buffers samples fed before output() is wired, losing nothing")
    func feedBeforeOutput() async {
        let mixer = AudioMixer()
        // No continuation yet — emitReady's early return path; data stays buffered.
        await mixer.feed(.microphone, [0.1])
        await mixer.feed(.system, [0.4])
        let stream = await mixer.output()
        await mixer.feed(.microphone, [0.2])
        await mixer.feed(.system, [0.5]) // now both buffered pairs drain together
        await mixer.finish(.microphone)
        await mixer.finish(.system)

        let frames = await collect(stream)
        #expect(frames.flatMap(\.samples) == [Float(0.1) + 0.4, Float(0.2) + 0.5])
    }

    @Test("output() returns the same stream on repeated calls")
    func outputIsStable() async {
        let mixer = AudioMixer()
        let stream = await mixer.output()
        _ = await mixer.output() // hits the cached-stream branch
        await mixer.feed(.microphone, [0.1])
        await mixer.feed(.system, [0.2])
        await mixer.finish(.microphone)
        await mixer.finish(.system)

        // The originally-vended stream still receives the audio.
        let frames = await collect(stream)
        #expect(frames.flatMap(\.samples) == [Float(0.1) + 0.2])
    }
}
