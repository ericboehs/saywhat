import Foundation
import Testing
@testable import SayWhatCore

/// Echo suppression: when the user is on speakers the remote bleeds into the mic
/// track, so the merge must drop the mic copy without losing the user's own words.
@Suite("TranscriptMerger echo suppression")
struct TranscriptMergerEchoTests {
    /// A finalized segment on one track over `start..<end` seconds.
    private func segment(
        _ source: CaptureSource,
        _ text: String,
        from start: Double,
        to end: Double
    ) -> TranscriptSegment {
        TranscriptSegment(
            source: source,
            text: text,
            range: .seconds(start) ..< .seconds(end),
            isFinal: true
        )
    }

    @Test("drops a mic segment that echoes an overlapping remote line")
    func dropsEcho() {
        // The remote bled through the speakers, so the mic re-transcribed it; the
        // recognizer hears the echo slightly differently ("made" vs "built").
        let mic = [segment(.microphone, "what is rage blade made of", from: 0, to: 5)]
        let system = [segment(.system, "what is rage blade built of", from: 0, to: 5)]
        let result = TranscriptMerger().merge(
            mic: mic,
            system: system,
            remoteSpeakers: SpeakerTimeline()
        )

        #expect(result.utterances.map(\.speaker) == [.remote(0)])
    }

    @Test("keeps the user's real words said in the same breath as an echo")
    func keepsRealWordsBesideEcho() {
        let mic = [
            segment(.microphone, "what is rage blade made of", from: 0, to: 5),
            segment(.microphone, "mic check one two three", from: 5, to: 7),
        ]
        let system = [segment(.system, "what is rage blade built of", from: 0, to: 5)]
        let result = TranscriptMerger().merge(
            mic: mic,
            system: system,
            remoteSpeakers: SpeakerTimeline()
        )

        #expect(result.utterances.map(\.speaker) == [.remote(0), .you])
        #expect(result.utterances.last?.text == "mic check one two three")
    }

    @Test("keeps a short reply the user genuinely echoes")
    func keepsShortEcho() {
        let mic = [segment(.microphone, "yeah okay", from: 0, to: 1)]
        let system = [segment(.system, "yeah okay sure thing", from: 0, to: 1)]
        let result = TranscriptMerger().merge(
            mic: mic,
            system: system,
            remoteSpeakers: SpeakerTimeline()
        )

        #expect(result.utterances.contains { $0.speaker == .you })
    }

    @Test("matching words far apart in time are not treated as echo")
    func keepsDistantMatch() {
        let mic = [segment(.microphone, "what is rage blade made of", from: 100, to: 105)]
        let system = [segment(.system, "what is rage blade made of", from: 0, to: 5)]
        let result = TranscriptMerger().merge(
            mic: mic,
            system: system,
            remoteSpeakers: SpeakerTimeline()
        )

        #expect(result.utterances.contains { $0.speaker == .you })
    }

    @Test("a genuine interjection over remote speech is kept")
    func keepsSimultaneousInterjection() {
        let mic = [segment(.microphone, "i totally disagree with everything", from: 0, to: 3)]
        let system = [segment(.system, "the farm is actually decent", from: 0, to: 3)]
        let result = TranscriptMerger().merge(
            mic: mic,
            system: system,
            remoteSpeakers: SpeakerTimeline()
        )

        #expect(result.utterances.contains { $0.speaker == .you })
    }

    @Test("a punctuation-only remote segment never absorbs an overlapping mic line")
    func echoIgnoresEmptyRemote() {
        let mic = [segment(.microphone, "what is rage blade made", from: 0, to: 3)]
        let system = [segment(.system, ".", from: 0, to: 3)]
        let result = TranscriptMerger().merge(
            mic: mic,
            system: system,
            remoteSpeakers: SpeakerTimeline()
        )

        #expect(result.utterances.map(\.speaker) == [.you])
    }
}
