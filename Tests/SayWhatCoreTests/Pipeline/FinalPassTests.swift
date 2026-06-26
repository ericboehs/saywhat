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

        let transcript = try await pass.run(session)

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

        let transcript = try await pass.run(session)

        #expect(transcript.utterances.map(\.speaker) == [.you])
        #expect(transcript.utterances.map(\.text) == ["solo"])
    }
}
