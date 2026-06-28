import Foundation
import Synchronization
import Testing
@testable import SayWhatCore

/// A model-free ``Transcriber`` that drains its input and replays a scripted set
/// of segments re-tagged with its own source — stands in for Parakeet.
private struct FakeTranscriber: Transcriber {
    let source: CaptureSource
    let script: [TranscriptSegment]

    func transcribe(
        _ frames: AsyncStream<AudioFrame>
    ) async throws -> AsyncThrowingStream<TranscriptSegment, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for await _ in frames {}
                for segment in script {
                    continuation.yield(TranscriptSegment(
                        source: source,
                        text: segment.text,
                        range: segment.range,
                        isFinal: segment.isFinal
                    ))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// A ``Transcriber`` that drains its input and then never finishes — stands in
/// for a wedged engine so the watchdog has something to trip on.
private struct HangingTranscriber: Transcriber {
    let source: CaptureSource

    func transcribe(
        _ frames: AsyncStream<AudioFrame>
    ) async throws -> AsyncThrowingStream<TranscriptSegment, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for await _ in frames {}
                try? await Task.sleep(for: .seconds(3600))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// A model-free ``SpeakerEmbedder`` that hands back scripted identity vectors in
/// call order — stands in for the WeSpeaker model. `FinalPass` embeds slots in
/// sorted order, so the first vector lands on the lowest slot.
private final class ScriptedEmbedder: SpeakerEmbedder, @unchecked Sendable {
    private let vectors: Mutex<[[Float]]>

    init(_ vectors: [[Float]]) {
        self.vectors = Mutex(vectors)
    }

    func embedding(for _: [Float]) async throws -> [Float]? {
        vectors.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }
}

/// A model-free ``Diarizer`` that drains its input and emits one canned timeline.
private struct FakeDiarizer: Diarizer {
    let timeline: SpeakerTimeline

    func diarize(_ frames: AsyncStream<AudioFrame>) async throws -> AsyncStream<SpeakerTimeline> {
        AsyncStream { continuation in
            let task = Task {
                for await _ in frames {}
                continuation.yield(timeline)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite("FinalPass")
struct FinalPassTests {
    /// Write a tone to one track so the session has real, decodable AAC for
    /// ``RecordingReader`` to stream back.
    private func writeTrack(
        _ source: CaptureSource,
        in session: RecordingSession,
        seconds: Int
    ) async throws {
        let writer = try session.writer(for: source)
        for index in 0 ..< seconds {
            let samples = (0 ..< 16000).map { Float(sin(Double($0) * 0.05)) }
            try await writer.append(AudioFrame(
                source: source,
                startOffset: .seconds(index),
                samples: samples
            ))
        }
        try await writer.finalize()
    }

    private func makeSession() -> RecordingSession {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("finalpass-\(UUID().uuidString)", isDirectory: true)
        return RecordingSession(directory: dir)
    }

    /// Enroll a person with a single exemplar embedding into `store`.
    private func enroll(_ store: VoiceprintStore, _ name: String, _ embedding: [Float]) throws {
        let person = Person(name: name)
        try store.savePerson(person)
        try store.save(Voiceprint(personID: person.id, embedding: embedding))
    }

    private func script(
        _ source: CaptureSource,
        _ text: String,
        _ from: Double,
        _ to: Double
    ) -> TranscriptSegment {
        TranscriptSegment(
            source: source,
            text: text,
            range: .seconds(from) ..< .seconds(to),
            isFinal: true
        )
    }

    @Test("merges both tracks and the diarized timeline into the authoritative transcript")
    func mergesEverything() async throws {
        let session = makeSession()
        try session.createDirectory()
        try await writeTrack(.microphone, in: session, seconds: 3)
        try await writeTrack(.system, in: session, seconds: 3)
        defer { try? FileManager.default.removeItem(at: session.directory) }

        let micScript = [script(.microphone, "hello there", 0, 1)]
        let systemScript = [script(.system, "hi back", 1, 2)]
        // Remote speech in 1..2 belongs to slot 1.
        let timeline = SpeakerTimeline(turns: [
            SpeakerTurn(speaker: 1, range: .seconds(1) ..< .seconds(2)),
        ])

        let pass = FinalPass(
            diarizer: FakeDiarizer(timeline: timeline),
            makeTranscriber: { source in
                FakeTranscriber(
                    source: source,
                    script: source == .microphone ? micScript : systemScript
                )
            }
        )

        let transcript = try await pass.run(session).transcript

        #expect(transcript.utterances.map(\.speaker) == [.you, .remote(1)])
        #expect(transcript.utterances.map(\.text) == ["hello there", "hi back"])
    }

    @Test("reports phases in order")
    func reportsPhases() async throws {
        let session = makeSession()
        try session.createDirectory()
        try await writeTrack(.microphone, in: session, seconds: 1)
        try await writeTrack(.system, in: session, seconds: 1)
        defer { try? FileManager.default.removeItem(at: session.directory) }

        let phases = Mutex<[FinalPass.Phase]>([])
        let pass = FinalPass(
            diarizer: FakeDiarizer(timeline: SpeakerTimeline()),
            makeTranscriber: { FakeTranscriber(source: $0, script: []) }
        )

        _ = try await pass.run(session) { phase in
            phases.withLock { $0.append(phase) }
        }

        let captured: [FinalPass.Phase] = phases.withLock { $0 }
        #expect(captured == [
            .transcribing(.microphone),
            .transcribing(.system),
            .diarizing,
            .merging,
        ])
    }

    @Test("a wedged transcriber trips the watchdog instead of hanging the pass")
    func transcriberTimeout() async throws {
        let session = makeSession()
        try session.createDirectory()
        try await writeTrack(.microphone, in: session, seconds: 1)
        defer { try? FileManager.default.removeItem(at: session.directory) }

        let pass = FinalPass(
            diarizer: FakeDiarizer(timeline: SpeakerTimeline()),
            budget: { _ in .milliseconds(50) },
            makeTranscriber: { HangingTranscriber(source: $0) }
        )

        await #expect(throws: TimeoutError(label: "transcribe(microphone)")) {
            _ = try await pass.run(session)
        }
    }

    @Test("a session with no system track still produces the mic transcript")
    func micOnly() async throws {
        let session = makeSession()
        try session.createDirectory()
        try await writeTrack(.microphone, in: session, seconds: 2)
        defer { try? FileManager.default.removeItem(at: session.directory) }

        let pass = FinalPass(
            diarizer: FakeDiarizer(timeline: SpeakerTimeline()),
            makeTranscriber: { source in
                FakeTranscriber(source: source, script: [script(.microphone, "solo", 0, 1)])
            }
        )

        let transcript = try await pass.run(session).transcript

        #expect(transcript.utterances.map(\.speaker) == [.you])
        #expect(transcript.utterances.map(\.text) == ["solo"])
    }

    @Test("resolves a known speaker to their name and labels newcomers without persisting them")
    func resolvesIdentities() async throws {
        let session = makeSession()
        try session.createDirectory()
        try await writeTrack(.system, in: session, seconds: 2)
        defer { try? FileManager.default.removeItem(at: session.directory) }

        let store = try VoiceprintStore()
        try enroll(store, "Eric", [1, 0])

        // Slot 0's audio (0..1s) ≈ enrolled Eric; slot 1's (1..2s) matches nobody
        // and should mint an un-named speaker. Identity comes from the embedder
        // over each slot's audio — the embedder scripts slot 0 then slot 1 in
        // sorted order.
        let timeline = SpeakerTimeline(turns: [
            SpeakerTurn(speaker: 0, range: .seconds(0) ..< .seconds(1)),
            SpeakerTurn(speaker: 1, range: .seconds(1) ..< .seconds(2)),
        ])
        let systemScript = [script(.system, "hello", 0, 1), script(.system, "hi", 1, 2)]
        let pass = FinalPass(
            diarizer: FakeDiarizer(timeline: timeline),
            store: store,
            embedder: ScriptedEmbedder([[0.99, 0.01], [0, 1]]),
            makeTranscriber: { source in
                FakeTranscriber(source: source, script: source == .system ? systemScript : [])
            }
        )

        let outcome = try await pass.run(session)

        #expect(outcome.transcript.utterances.map(\.speakerName) == ["Eric", "Speaker 1"])
        // The newcomer is *not* persisted — an un-named mint stays in memory until
        // the user names it, so the directory keeps only the one enrolled person.
        #expect(try store.enrolledPersons().map(\.person.name) == ["Eric"])
        // Each remote slot surfaces how it resolved, so the UI can name it.
        #expect(outcome.speakers[0]?.person?.name == "Eric")
        #expect(outcome.speakers[0]?.name == "Eric")
        #expect(outcome.speakers[1]?.person == nil)
        #expect(outcome.speakers[1]?.name == "Speaker 1")
    }

    @Test("each remote utterance carries its own voiceprint, not the group's")
    func attributesUtteranceVoiceprints() async throws {
        let session = makeSession()
        try session.createDirectory()
        try await writeTrack(.system, in: session, seconds: 2)
        defer { try? FileManager.default.removeItem(at: session.directory) }

        let store = try VoiceprintStore()
        try enroll(store, "Eric", [1, 0])
        let timeline = SpeakerTimeline(turns: [
            SpeakerTurn(speaker: 0, range: .seconds(0) ..< .seconds(1)),
            SpeakerTurn(speaker: 1, range: .seconds(1) ..< .seconds(2)),
        ])
        let systemScript = [script(.system, "hello", 0, 1), script(.system, "hi", 1, 2)]
        let pass = FinalPass(
            diarizer: FakeDiarizer(timeline: timeline),
            store: store,
            embedder: ScriptedEmbedder([[0.99, 0.01], [0, 1]]),
            makeTranscriber: { source in
                FakeTranscriber(source: source, script: source == .system ? systemScript : [])
            }
        )

        // Each remote utterance (ids 0,1) is attributed the embedding of the turn it
        // overlaps — its *own* voice, so a mis-grouped one can be reassigned later.
        let prints = try await pass.run(session).utteranceVoiceprints
        #expect([prints[0]?.embedding, prints[1]?.embedding] == [[0.99, 0.01], [0, 1]])
    }

    @Test("splits one diarizer slot fused across two voices into two speakers")
    func splitsFusedSlot() async throws {
        let session = makeSession()
        try session.createDirectory()
        try await writeTrack(.system, in: session, seconds: 2)
        defer { try? FileManager.default.removeItem(at: session.directory) }

        let store = try VoiceprintStore()
        try enroll(store, "Theo", [1, 0])

        // The Theo+MKBHD failure: the diarizer put both turns in *one* slot (0).
        // Per-turn embedding (Theo-ish then a stranger) must re-segment them into
        // two groups, name the first Theo, and mint the second.
        let timeline = SpeakerTimeline(turns: [
            SpeakerTurn(speaker: 0, range: .seconds(0) ..< .seconds(1)),
            SpeakerTurn(speaker: 0, range: .seconds(1) ..< .seconds(2)),
        ])
        let systemScript = [
            script(.system, "context lives", 0, 1),
            script(.system, "slate truck", 1, 2),
        ]
        let pass = FinalPass(
            diarizer: FakeDiarizer(timeline: timeline),
            store: store,
            embedder: ScriptedEmbedder([[0.98, 0.02], [0, 1]]),
            makeTranscriber: { source in
                FakeTranscriber(source: source, script: source == .system ? systemScript : [])
            }
        )

        let outcome = try await pass.run(session)

        #expect(outcome.transcript.utterances.map(\.speakerName) == ["Theo", "Speaker 1"])
        #expect(outcome.transcript.utterances.map(\.text) == ["context lives", "slate truck"])
        #expect(outcome.speakers[0]?.person?.name == "Theo")
        #expect(outcome.speakers[1]?.person == nil)
    }

    @Test("without an embedder, identities are left unresolved")
    func noEmbedderNoNames() async throws {
        let session = makeSession()
        try session.createDirectory()
        try await writeTrack(.system, in: session, seconds: 1)
        defer { try? FileManager.default.removeItem(at: session.directory) }

        let store = try VoiceprintStore()
        try enroll(store, "Eric", [1, 0])

        let timeline = SpeakerTimeline(turns: [
            SpeakerTurn(speaker: 0, range: .seconds(0) ..< .seconds(1)),
        ])
        // No embedder wired: the pass can't place the voice in the identity
        // space, so it falls back to a generic label rather than guessing.
        let pass = FinalPass(
            diarizer: FakeDiarizer(timeline: timeline),
            store: store,
            makeTranscriber: { source in
                FakeTranscriber(
                    source: source,
                    script: source == .system ? [script(.system, "hi", 0, 1)] : []
                )
            }
        )

        let transcript = try await pass.run(session).transcript

        #expect(transcript.utterances.first?.speakerName == nil)
    }

    @Test("a slot with too little audio to embed is left unresolved")
    func shortSlotUnresolved() async throws {
        let session = makeSession()
        try session.createDirectory()
        try await writeTrack(.system, in: session, seconds: 1)
        defer { try? FileManager.default.removeItem(at: session.directory) }

        let store = try VoiceprintStore()
        try enroll(store, "Eric", [1, 0])

        // The slot's only turn (5..6s) falls past the one second of recorded
        // audio, so no frames slice into it and the embedder is never consulted —
        // the slot stays generic even though its scripted vector would have
        // matched Eric.
        let timeline = SpeakerTimeline(turns: [
            SpeakerTurn(speaker: 0, range: .seconds(5) ..< .seconds(6)),
        ])
        let pass = FinalPass(
            diarizer: FakeDiarizer(timeline: timeline),
            store: store,
            embedder: ScriptedEmbedder([[1, 0]]),
            makeTranscriber: { source in
                FakeTranscriber(
                    source: source,
                    script: source == .system ? [script(.system, "hi", 0, 1)] : []
                )
            }
        )

        let transcript = try await pass.run(session).transcript

        #expect(transcript.utterances.first?.speakerName == nil)
    }
}
