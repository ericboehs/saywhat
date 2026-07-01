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

    /// Splits the track into silence-cut, ≤-cap windows so no clause is lost on
    /// one of FluidAudio's internal chunk seams (see ``AudioWindower``).
    private let windower: AudioWindower

    public init(
        source: CaptureSource,
        models: AsrModels? = nil,
        utterancePause: Duration = .milliseconds(600)
    ) {
        self.source = source
        self.models = models
        builder = ParakeetSegmentBuilder(source: source, utterancePause: utterancePause)
        windower = AudioWindower()
    }

    public func transcribe(
        _ frames: AsyncStream<AudioFrame>
    ) async throws -> AsyncThrowingStream<TranscriptSegment, Error> {
        let models = try await loadedModels()
        let builder = builder
        let windower = windower

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

                    // `melChunkContext: false` — the 80 ms mel-context prepend
                    // FluidAudio enables by default (PR #264) shifts the v3
                    // encoder's first-frame distribution on long-form audio
                    // enough that the TDT decoder drifts to blank and **drops a
                    // whole clause** at chunk boundaries (FluidAudio issue #594).
                    // Verified on real sessions: the default path silently
                    // omitted ~5 s of remote speech a user had interjected over,
                    // making their reply read as misplaced. The no-mel path
                    // (acoustic warmup + silence-aligned starts) recovers it.
                    let manager = AsrManager(
                        config: ASRConfig(melChunkContext: false),
                        models: models
                    )

                    // Split the track into ≤-cap windows cut in silence, so no
                    // clause straddles one of FluidAudio's internal ~15 s seams —
                    // where #594 still drops it even with the no-mel path. Each
                    // window is short enough to take FluidAudio's single-window
                    // path (no cross-window dedup), and the cuts land in pauses
                    // where there is no word to lose. We transcribe each window
                    // independently and shift its token timings back onto the
                    // track timeline by the window's start offset.
                    let sampleRate = Double(AudioStreamFormat.model.sampleRate)
                    var tokens: [TimedToken] = []
                    var fallbackText = ""
                    for window in windower.windows(samples) {
                        let piece = Array(samples[window])
                        var state = try TdtDecoderState()
                        let result = try await manager.transcribe(piece, decoderState: &state)
                        let offset = Duration.seconds(Double(window.lowerBound) / sampleRate)
                        tokens.append(contentsOf: (result.tokenTimings ?? []).map {
                            TimedToken(
                                text: $0.token,
                                start: offset + .seconds($0.startTime),
                                end: offset + .seconds($0.endTime)
                            )
                        })
                        if !result.text.isEmpty {
                            fallbackText += fallbackText.isEmpty ? result.text : " " + result.text
                        }
                    }
                    let segments = builder.segments(
                        tokens: tokens,
                        fallbackText: fallbackText,
                        fallbackDuration: .seconds(Double(samples.count) / sampleRate),
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
