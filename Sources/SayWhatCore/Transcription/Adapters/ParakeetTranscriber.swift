import AVFoundation
import FluidAudio
import Foundation

/// Errors surfaced by ``ParakeetTranscriber``.
public enum ParakeetError: Error, Sendable, Equatable {
    /// The Parakeet CoreML models could not be downloaded or loaded.
    case modelsUnavailable
}

/// Batch ``Transcriber`` for the **final pass**, backed by FluidAudio's Parakeet
/// TDT v3 (`AsrManager`). One instance per track, per the separate-tracks
/// invariant; runs at meeting end over the saved audio that ``RecordingReader``
/// streams back, producing the higher-accuracy authoritative transcription that
/// replaces the live Apple-Speech result. The model runs on the Neural Engine
/// and never leaves the device (DESIGN.md §3, §5; CLAUDE.md tech stack).
///
/// Unlike the live path there is no volatile stage: the final pass commits each
/// utterance once. We concatenate the track's frames, transcribe in one batch
/// (TDT carries decoder state across its own internal sliding windows), then
/// hand the per-token timings to ``ParakeetSegmentBuilder`` — the pure, tested
/// seam that splits them into utterance-level **final** ``TranscriptSegment``s
/// on speech pauses, giving the merge step real time ranges to interleave on.
///
/// This is a hardware/ML adapter (coverage-excluded): the contract it satisfies
/// is exercised through ``Transcriber`` fakes, and its accuracy is a
/// golden-file/WER concern, not a unit-test one. See QUALITY.md §6.
public final class ParakeetTranscriber: Transcriber {
    public let source: CaptureSource

    /// Pre-loaded models, when the caller wants to share one download across both
    /// tracks; otherwise they are downloaded/loaded lazily on first transcribe.
    private let models: AsrModels?

    /// Shapes the model's token timings into readable, timeline-placed segments.
    private let builder: ParakeetSegmentBuilder

    public init(
        source: CaptureSource,
        models: AsrModels? = nil,
        utterancePause: Duration = .milliseconds(600)
    ) {
        self.source = source
        self.models = models
        builder = ParakeetSegmentBuilder(source: source, utterancePause: utterancePause)
    }

    public func transcribe(
        _ frames: AsyncStream<AudioFrame>
    ) async throws -> AsyncThrowingStream<TranscriptSegment, Error> {
        let models = try await loadedModels()
        let builder = builder

        return AsyncThrowingStream<TranscriptSegment, Error> { continuation in
            let task = Task {
                do {
                    // Concatenate the track back into one buffer. The frames are
                    // already 16 kHz mono Float32 (the model format), so Parakeet
                    // consumes them directly with no resample.
                    var samples: [Float] = []
                    var base: Duration?
                    for await frame in frames {
                        if base == nil { base = frame.startOffset }
                        samples.append(contentsOf: frame.samples)
                    }
                    guard !samples.isEmpty else {
                        continuation.finish()
                        return
                    }

                    let manager = AsrManager(models: models)
                    var state = try TdtDecoderState()
                    let result = try await manager.transcribe(samples, decoderState: &state)

                    let tokens = (result.tokenTimings ?? []).map {
                        TimedToken(
                            text: $0.token,
                            start: .seconds($0.startTime),
                            end: .seconds($0.endTime)
                        )
                    }
                    let segments = builder.segments(
                        tokens: tokens,
                        fallbackText: result.text,
                        fallbackDuration: .seconds(result.duration),
                        base: base ?? .zero
                    )
                    for segment in segments {
                        continuation.yield(segment)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The injected models, or a fresh download/load of Parakeet TDT v3.
    private func loadedModels() async throws -> AsrModels {
        if let models { return models }
        do {
            return try await AsrModels.downloadAndLoad(version: .v3)
        } catch {
            throw ParakeetError.modelsUnavailable
        }
    }
}
