import Testing
@testable import SayWhatCore

@Suite("Audio format & frame")
struct AudioFormatTests {
    @Test("model format is 16 kHz mono")
    func modelFormat() {
        #expect(AudioStreamFormat.model.sampleRate == 16000)
        #expect(AudioStreamFormat.model.channelCount == 1)
    }

    @Test("sample count scales with duration")
    func sampleCount() {
        #expect(AudioStreamFormat.model.sampleCount(for: .seconds(1)) == 16000)
        #expect(AudioStreamFormat.model.sampleCount(for: .milliseconds(500)) == 8000)
        #expect(AudioStreamFormat.model.sampleCount(for: .zero) == 0)
    }

    @Test("frame duration matches its sample count at the model rate")
    func frameDuration() {
        let frame = AudioFrame(
            source: .microphone,
            startOffset: .zero,
            samples: [Float](repeating: 0, count: 16000)
        )
        #expect(frame.duration == .seconds(1))
    }

    @Test("a frame keeps its source and offset")
    func frameIdentity() {
        let frame = AudioFrame(source: .system, startOffset: .seconds(3), samples: [0.1, 0.2])
        #expect(frame.source == .system)
        #expect(frame.startOffset == .seconds(3))
        #expect(frame.samples.count == 2)
    }
}
