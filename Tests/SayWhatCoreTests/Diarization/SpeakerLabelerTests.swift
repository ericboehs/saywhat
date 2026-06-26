import Foundation
import Testing
@testable import SayWhatCore

@Suite("SpeakerLabeler")
struct SpeakerLabelerTests {
    /// A constant-level frame: RMS equals `level`, duration equals `seconds`.
    private func frame(at start: Double, seconds: Double, level: Float) -> AudioFrame {
        let count = max(1, Int(seconds * Double(AudioStreamFormat.model.sampleRate)))
        return AudioFrame(
            source: .system,
            startOffset: .seconds(start),
            samples: Array(repeating: level, count: count)
        )
    }

    private let window: Range<Duration> = .seconds(0) ..< .seconds(1)

    @Test("a loud mic over a quiet system window is you")
    func youWhenMicDominant() {
        var mic = EnergyTrack()
        var system = EnergyTrack()
        mic.record(frame(at: 0, seconds: 1, level: 0.5))
        system.record(frame(at: 0, seconds: 1, level: 0.01))
        let label = SpeakerLabeler().label(
            segment: window,
            mic: mic,
            system: system,
            remoteSpeakers: SpeakerTimeline()
        )
        #expect(label == .you)
    }

    @Test("a loud system with only mic echo is the diarized remote speaker")
    func remoteWhenSystemDominant() {
        var mic = EnergyTrack()
        var system = EnergyTrack()
        mic.record(frame(at: 0, seconds: 1, level: 0.1)) // attenuated echo
        system.record(frame(at: 0, seconds: 1, level: 0.5))
        let timeline = SpeakerTimeline(turns: [
            SpeakerTurn(speaker: 2, range: window),
        ])
        let label = SpeakerLabeler().label(
            segment: window,
            mic: mic,
            system: system,
            remoteSpeakers: timeline
        )
        #expect(label == .remote(2))
    }

    @Test("the echo bias keeps a moderate mic bleed attributed to remote")
    func echoBias() {
        var mic = EnergyTrack()
        var system = EnergyTrack()
        // 0.4 vs 0.5: mic is louder than system but not 1.5× → remote, not you.
        mic.record(frame(at: 0, seconds: 1, level: 0.4))
        system.record(frame(at: 0, seconds: 1, level: 0.5))
        let label = SpeakerLabeler().label(
            segment: window,
            mic: mic,
            system: system,
            remoteSpeakers: SpeakerTimeline()
        )
        #expect(label == .remote(0))
    }

    @Test("remote with no diarized turn falls back to slot 0")
    func remoteFallback() {
        var mic = EnergyTrack()
        var system = EnergyTrack()
        mic.record(frame(at: 0, seconds: 1, level: 0.1))
        system.record(frame(at: 0, seconds: 1, level: 0.5))
        let label = SpeakerLabeler().label(
            segment: window,
            mic: mic,
            system: system,
            remoteSpeakers: SpeakerTimeline()
        )
        #expect(label == .remote(0))
    }

    @Test("energy reads zero outside any recorded span")
    func energyOutsideSpans() {
        var track = EnergyTrack()
        track.record(frame(at: 0, seconds: 1, level: 0.5))
        #expect(track.energy(in: .seconds(5) ..< .seconds(6)) == 0)
    }
}
