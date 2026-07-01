import SayWhatCore
import Testing
@testable import SayWhatBench

@Suite("DiarizationScore")
struct DiarizationScoreTests {
    /// A speaker span; text is irrelevant to diarization scoring.
    private struct Span {
        let speaker: SpeakerLabel
        let start: Double
        let end: Double
    }

    private static func transcript(_ spans: [Span]) -> Transcript {
        Transcript(utterances: spans.enumerated().map { index, span in
            Transcript.Utterance(
                id: index,
                speaker: span.speaker,
                text: "x",
                range: .seconds(span.start) ..< .seconds(span.end)
            )
        })
    }

    @Test("identical segmentation scores zero DER and full consistency")
    func perfect() {
        let truth = Self.transcript([
            Span(speaker: .remote(0), start: 0, end: 10),
            Span(speaker: .remote(1), start: 10, end: 20),
        ])
        let score = DiarizationScore(hypothesis: truth, reference: truth)
        #expect(score.der == 0)
        #expect(score.clusterConsistency == 1)
    }

    @Test("arbitrary but consistent cluster ids still score perfectly via mapping")
    func relabeledButConsistent() {
        // Same structure, but the hypothesis swaps which slot id each speaker got.
        let reference = Self.transcript([
            Span(speaker: .remote(0), start: 0, end: 10),
            Span(speaker: .remote(1), start: 10, end: 20),
        ])
        let hypothesis = Self.transcript([
            Span(speaker: .remote(1), start: 0, end: 10),
            Span(speaker: .remote(0), start: 10, end: 20),
        ])
        let score = DiarizationScore(hypothesis: hypothesis, reference: reference)
        #expect(score.der == 0)
        #expect(score.clusterConsistency == 1)
    }

    @Test("fusing two speakers into one cluster is charged as confusion")
    func fusedSpeakers() {
        let reference = Self.transcript([
            Span(speaker: .remote(0), start: 0, end: 10),
            Span(speaker: .remote(1), start: 10, end: 20),
        ])
        // Hypothesis calls everyone the same speaker: one of the two halves is wrong
        // after the best mapping — ~50% of reference time mislabeled.
        let hypothesis = Self.transcript([Span(speaker: .remote(0), start: 0, end: 20)])
        let score = DiarizationScore(hypothesis: hypothesis, reference: reference)
        #expect(abs(score.der - 0.5) < 1e-6)
        #expect(abs(score.clusterConsistency - 0.5) < 1e-6)
    }

    @Test("missed speech (a gap where the reference speaks) raises DER")
    func missedSpeech() {
        let reference = Self.transcript([Span(speaker: .remote(0), start: 0, end: 20)])
        // Hypothesis only covers the first half; the rest is unlabeled silence.
        let hypothesis = Self.transcript([Span(speaker: .remote(0), start: 0, end: 10)])
        let score = DiarizationScore(hypothesis: hypothesis, reference: reference)
        #expect(abs(score.der - 0.5) < 1e-6)
    }

    @Test("compares on resolved names when both sides carry them")
    func comparesOnNames() {
        let reference = Transcript(utterances: [
            Transcript.Utterance(
                id: 0,
                speaker: .remote(0),
                speakerName: "Allison",
                text: "x",
                range: .seconds(0) ..< .seconds(10)
            ),
            Transcript.Utterance(
                id: 1,
                speaker: .remote(1),
                speakerName: "Jason",
                text: "x",
                range: .seconds(10) ..< .seconds(20)
            ),
        ])
        // Hypothesis used different slot numbers but resolved the same names.
        let hypothesis = Transcript(utterances: [
            Transcript.Utterance(
                id: 0,
                speaker: .remote(3),
                speakerName: "Allison",
                text: "x",
                range: .seconds(0) ..< .seconds(10)
            ),
            Transcript.Utterance(
                id: 1,
                speaker: .remote(7),
                speakerName: "Jason",
                text: "x",
                range: .seconds(10) ..< .seconds(20)
            ),
        ])
        let score = DiarizationScore(hypothesis: hypothesis, reference: reference)
        #expect(score.der == 0)
        #expect(score.clusterConsistency == 1)
    }
}
