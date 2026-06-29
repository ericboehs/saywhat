import Foundation
import Testing
@testable import SayWhatCore

/// A manual, machine-local validation of identity-driven re-segmentation against a
/// **real** finalized recording with the **real** ML engines — the empirical check
/// the scripted-embedding unit tests can't make: do live `wespeaker_v2` vectors
/// actually pull two voices the diarizer fused into one slot back apart?
///
/// Disabled unless `SAYWHAT_SESSION` (a finalized session directory) and
/// `SAYWHAT_DB` (a voiceprints.sqlite) are set, so CI — which has no models and no
/// recording — never runs it. It downloads the FluidAudio models to Application
/// Support on first use. Run it from the repo with, e.g.:
///
///     SAYWHAT_SESSION=/path/to/session-1782611830 \
///     SAYWHAT_DB=/path/to/voiceprints.sqlite \
///     swift test --filter RealResegmentation
@Suite("RealResegmentation")
struct RealResegmentationHarness {
    private static var session: String? {
        ProcessInfo.processInfo.environment["SAYWHAT_SESSION"]
    }

    private static var database: String? {
        ProcessInfo.processInfo.environment["SAYWHAT_DB"]
    }

    @Test(
        "re-segments a real recording, printing who each turn resolved to",
        .enabled(if: session != nil && database != nil)
    )
    func resegmentRealRecording() async throws {
        let sessionDir = try URL(fileURLWithPath: #require(Self.session))
        let store = try VoiceprintStore(path: #require(Self.database))

        let enrolled = try store.enrolledPersons()
        print("── enrolled directory ──")
        for person in enrolled {
            print("  \(person.person.name): \(person.exemplars.count) exemplar(s)")
        }

        let pass = FinalPass(
            diarizer: SortformerLiveDiarizer(),
            store: store,
            embedder: WeSpeakerEmbedder(),
            makeTranscriber: { ParakeetTranscriber(source: $0) }
        )

        let outcome = try await pass.run(RecordingSession(directory: sessionDir)) { phase in
            print("── phase: \(phase) ──")
        }

        print("── resolved groups ──")
        for (group, resolved) in outcome.speakers.sorted(by: { $0.key < $1.key }) {
            let kind = resolved.person == nil ? "MINTED" : "matched"
            print("  group \(group): \(resolved.name) [\(kind)]")
        }

        print("── transcript ──")
        for utterance in outcome.transcript.utterances {
            let start = utterance.range.lowerBound.seconds
            let end = utterance.range.upperBound.seconds
            let name = utterance.speakerName ?? "\(utterance.speaker)"
            print(String(format: "  [%6.1f–%6.1f] %@: %@", start, end, name, utterance.text))
        }

        // A second, independent pass over the system track to expose *why* each
        // turn landed where it did: original Sortformer slot, time span, whether it
        // embedded, similarity to each enrolled person, and the group the
        // re-segmenter assigned. This is the ground truth the transcript hides.
        try await dumpTurnTable(sessionDir: sessionDir, enrolled: enrolled)

        // The harness is for eyeballing the result; the only hard assertion is that
        // the pass produced something.
        #expect(!outcome.transcript.utterances.isEmpty)
    }

    /// Print one row per Sortformer turn with everything that decides its label.
    private func dumpTurnTable(sessionDir: URL, enrolled: [EnrolledPerson]) async throws {
        let reader = RecordingReader()
        var frames: [AudioFrame] = []
        for try await frame in reader.frames(
            for: .system,
            in: RecordingSession(directory: sessionDir)
        ) {
            frames.append(frame)
        }

        let diarizer = SortformerLiveDiarizer()
        var timeline = SpeakerTimeline()
        for await snapshot in try await diarizer.diarize(Self.stream(frames)) {
            timeline = snapshot
        }

        let embedder = WeSpeakerEmbedder()
        var embeddings: [Int: [Float]] = [:]
        for (index, turn) in timeline.turns.enumerated() {
            let samples = SpeakerAudio.samples(for: turn, from: frames)
            guard samples.count >= 16000 else { continue }
            if let vector = try? await embedder.embedding(for: samples) {
                embeddings[index] = vector
            }
        }

        let resegmenter = SpeakerResegmenter(
            resolver: SpeakerResolver(matcher: VoiceprintMatcher(threshold: 0.5))
        )
        let result = resegmenter.resegment(
            turns: timeline.turns,
            embeddings: embeddings,
            against: enrolled
        )

        print("── per-turn table (slot → group) ──")
        for (index, turn) in timeline.turns.enumerated() {
            let start = turn.range.lowerBound.seconds
            let end = turn.range.upperBound.seconds
            let group = result.timeline.turns[index].speaker
            let name = result.speakers[group]?.name ?? "?"
            var sims = ""
            if let vector = embeddings[index] {
                sims = enrolled.map { person in
                    let score = VoiceprintMatcher.bestSimilarity(vector, person.exemplars)
                    return String(format: "%@=%.2f", person.person.name, score)
                }.joined(separator: " ")
            } else {
                sims = "(no embed)"
            }
            let span = String(format: "[%6.1f–%6.1f]", start, end)
            print("  #\(index) slot\(turn.speaker) \(span) → g\(group) \(name)  \(sims)")
        }
    }

    private static func stream(_ frames: [AudioFrame]) -> AsyncStream<AudioFrame> {
        AsyncStream { continuation in
            for frame in frames {
                continuation.yield(frame)
            }
            continuation.finish()
        }
    }
}
