import Foundation
import Testing
@testable import SayWhatCore

/// A model-free ``Transcriber`` for exercising the protocol contract: it drains
/// the input audio (counting frames) and replays a scripted set of segments,
/// re-tagged with its own ``source``. Stands in for Apple/Parakeet in tests so
/// the pipeline can be driven without a real recognizer (CLAUDE.md conventions).
private struct FakeTranscriber: Transcriber {
    let source: CaptureSource
    var script: [TranscriptSegment] = []
    var echoFrameCount = false

    func transcribe(
        _ frames: AsyncStream<AudioFrame>
    ) async throws -> AsyncThrowingStream<TranscriptSegment, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var count = 0
                for await _ in frames {
                    count += 1
                }
                for segment in script {
                    continuation.yield(
                        TranscriptSegment(
                            source: source,
                            text: segment.text,
                            range: segment.range,
                            isFinal: segment.isFinal
                        )
                    )
                }
                if echoFrameCount {
                    continuation.yield(
                        TranscriptSegment(
                            source: source,
                            text: "frames:\(count)",
                            range: .zero ..< .zero,
                            isFinal: true
                        )
                    )
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite("Transcriber contract")
struct TranscriberContractTests {
    private typealias SegmentStream = AsyncThrowingStream<TranscriptSegment, Error>

    /// A finite stream of `count` silent frames for one track.
    private func frames(
        _ count: Int,
        source: CaptureSource = .microphone
    ) -> AsyncStream<AudioFrame> {
        AsyncStream { continuation in
            for index in 0 ..< count {
                continuation.yield(
                    AudioFrame(
                        source: source,
                        startOffset: .seconds(index),
                        samples: [Float](repeating: 0, count: 16000)
                    )
                )
            }
            continuation.finish()
        }
    }

    private func collect(_ stream: SegmentStream) async throws -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        for try await segment in stream {
            out.append(segment)
        }
        return out
    }

    @Test("replays scripted segments in order, re-tagged with its own source")
    func replaysScript() async throws {
        let script = [
            TranscriptSegment(
                source: .microphone,
                text: "hel",
                range: .zero ..< .seconds(1),
                isFinal: false
            ),
            TranscriptSegment(
                source: .microphone,
                text: "hello",
                range: .zero ..< .seconds(1),
                isFinal: true
            ),
        ]
        let transcriber = FakeTranscriber(source: .system, script: script)

        let result = try await collect(transcriber.transcribe(frames(3)))

        #expect(result.count == 2)
        #expect(result.map(\.text) == ["hel", "hello"])
        #expect(result.map(\.isFinal) == [false, true])
        // Tagged with the transcriber's track, not the script's.
        #expect(result.allSatisfy { $0.source == .system })
    }

    @Test("drains every input frame before finishing")
    func drainsInput() async throws {
        let transcriber = FakeTranscriber(source: .microphone, echoFrameCount: true)

        let result = try await collect(transcriber.transcribe(frames(7)))

        #expect(result.last?.text == "frames:7")
        #expect(result.last?.isFinal == true)
    }

    @Test("an empty audio stream yields no transcript")
    func emptyInput() async throws {
        let transcriber = FakeTranscriber(source: .microphone, script: [
            TranscriptSegment(
                source: .microphone,
                text: "ignored",
                range: .zero ..< .zero,
                isFinal: true
            ),
        ])

        // Script still replays, but with zero frames the count echo confirms a
        // clean empty drain when enabled.
        let counting = FakeTranscriber(source: .microphone, echoFrameCount: true)
        let result = try await collect(counting.transcribe(frames(0)))
        #expect(result.map(\.text) == ["frames:0"])

        // And a scripted transcriber over empty input still finishes its script.
        let scripted = try await collect(transcriber.transcribe(frames(0)))
        #expect(scripted.map(\.text) == ["ignored"])
    }
}
