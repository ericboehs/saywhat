import FluidAudio
import Foundation
import os

/// Offline ``Diarizer`` for the **final pass**, backed by FluidAudio's
/// `OfflineDiarizerManager` (pyannote community-1). Per the channel-diarization
/// tenet it is fed the **system track only** — the mic channel is already "you"
/// — and runs at meeting end over the saved audio that ``RecordingReader``
/// streams back, producing the authoritative ``SpeakerTimeline`` that replaces
/// the live Sortformer guess in the merge (DESIGN.md §3, §6).
///
/// Unlike the streaming Sortformer path this is a single batch: we accumulate
/// the whole track (already 16 kHz mono, the model's target rate), run one
/// `process`, and emit one final timeline snapshot. An actor so the loaded
/// models are cached across sessions under one isolation domain; the non-Sendable
/// CoreML manager is built and used entirely inside the processing task, never
/// shared. Models download once from HuggingFace to Application Support; nothing
/// else touches the network.
///
/// This is a hardware/ML adapter (coverage-excluded): the contract it satisfies
/// is exercised through ``Diarizer`` fakes, and its accuracy is a
/// golden-file/DER concern, not a unit-test one. The pure slot-mapping lives in
/// the tested ``OfflineTimelineBuilder``. See QUALITY.md §6.
public actor OfflinePyannoteDiarizer: SayWhatCore.Diarizer {
    private static let log = Logger(subsystem: "com.boehs.saywhat", category: "diarize.pyannote")

    private let config: OfflineDiarizerConfig
    private let builder = OfflineTimelineBuilder()
    private var models: OfflineDiarizerModels?

    public init(config: OfflineDiarizerConfig = .default) {
        self.config = config
    }

    public func diarize(
        _ frames: AsyncStream<AudioFrame>
    ) async throws -> AsyncStream<SpeakerTimeline> {
        let models = try await loadedModels()
        let config = config
        let builder = builder

        return AsyncStream<SpeakerTimeline> { continuation in
            let task = Task {
                var samples: [Float] = []
                for await frame in frames {
                    samples.append(contentsOf: frame.samples)
                }
                let timeline = await Self.process(
                    samples,
                    models: models,
                    config: config,
                    builder: builder
                )
                continuation.yield(timeline)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Load (downloading + compiling on first use) and cache the diarizer models.
    /// The Sendable model bundle is reused across sessions; the manager that
    /// consumes it is short-lived and built per call.
    private func loadedModels() async throws -> OfflineDiarizerModels {
        if let models { return models }
        let loaded = try await OfflineDiarizerModels.load()
        models = loaded
        Self.log.info("Offline pyannote diarizer models ready")
        return loaded
    }

    /// Batch-diarize the accumulated track and project the result onto our
    /// ``SpeakerTimeline``. A processing error is logged and swallowed as an
    /// empty timeline so diarization never takes down the final transcript.
    private static func process(
        _ samples: [Float],
        models: OfflineDiarizerModels,
        config: OfflineDiarizerConfig,
        builder: OfflineTimelineBuilder
    ) async -> SpeakerTimeline {
        guard !samples.isEmpty else { return SpeakerTimeline() }
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)
        do {
            let result = try await manager.process(audio: samples)
            let raw = result.segments.map {
                RawSpeakerSegment(
                    speakerId: $0.speakerId,
                    range: .seconds(Double($0.startTimeSeconds)) ..<
                        .seconds(Double($0.endTimeSeconds))
                )
            }
            // The per-speaker mean embedding (keyed by the same speakerId as the
            // segments) drives persistent identity resolution in the final pass.
            return builder.timeline(from: raw, speakerEmbeddings: result.speakerDatabase ?? [:])
        } catch {
            log.error("offline diarization failed: \(error.localizedDescription, privacy: .public)")
            return SpeakerTimeline()
        }
    }
}
