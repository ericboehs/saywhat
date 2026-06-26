import FluidAudio
import Foundation
import os

/// Live ``Diarizer`` backed by FluidAudio's streaming **Sortformer** model. Per
/// the channel-diarization tenet it is fed the **system track only**, so its job
/// is purely to split the remote speakers (up to 4 slots) — the mic channel is
/// already "you" (DESIGN.md §6).
///
/// An actor so the underlying `SortformerDiarizer` (a lock-guarded class running
/// CoreML inference) is confined to one isolation domain. Models download once
/// from HuggingFace on first use to Application Support; nothing else touches the
/// network.
///
/// This is a hardware/ML adapter (coverage-excluded): the pure contract it
/// satisfies is exercised through ``Diarizer`` fakes, and its accuracy is a
/// golden-file/DER concern, not a unit-test one. See DESIGN.md §6, QUALITY.md §6.
public actor SortformerLiveDiarizer: SayWhatCore.Diarizer {
    private static let log = Logger(subsystem: "com.boehs.saywhat", category: "diarize.sortformer")

    private let config: SortformerConfig
    private var engine: SortformerDiarizer?

    public init(config: SortformerConfig = .default) {
        self.config = config
    }

    public func diarize(
        _ frames: AsyncStream<AudioFrame>
    ) async throws -> AsyncStream<SpeakerTimeline> {
        try await ensureLoaded()

        return AsyncStream<SpeakerTimeline> { continuation in
            let task = Task {
                for await frame in frames {
                    if let snapshot = self.ingest(frame.samples) {
                        continuation.yield(snapshot)
                    }
                }
                continuation.yield(self.finalize())
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Load the Sortformer engine, downloading the model on first use. A reused
    /// instance is reset so each session starts from a clean timeline. The engine
    /// stays actor-isolated — it is never handed across an isolation boundary.
    private func ensureLoaded() async throws {
        if let engine {
            engine.reset()
            return
        }
        let engine = SortformerDiarizer(config: config)
        let models = try await SortformerModels.loadFromHuggingFace(config: config)
        engine.initialize(models: models)
        self.engine = engine
        let speakers = config.numSpeakers
        Self.log.info("Sortformer ready — up to \(speakers) speakers")
    }

    /// Feed one frame of system audio (already 16 kHz mono) and, if the model
    /// finalized new frames, return the refreshed timeline snapshot. A processing
    /// error is logged and swallowed so diarization never takes down the
    /// transcript.
    private func ingest(_ samples: [Float]) -> SpeakerTimeline? {
        guard let engine else { return nil }
        do {
            let update = try engine.process(samples: samples, sourceSampleRate: nil)
            return update == nil ? nil : snapshot()
        } catch {
            Self.log.error("process failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Flush the model's right-context preview and return the final timeline.
    private func finalize() -> SpeakerTimeline {
        guard let engine else { return SpeakerTimeline() }
        _ = try? engine.finalizeSession()
        return snapshot()
    }

    /// Project FluidAudio's accumulated timeline onto our ``SpeakerTimeline``:
    /// one ``SpeakerTurn`` per finalized segment, tagged with its speaker slot.
    private func snapshot() -> SpeakerTimeline {
        guard let engine else { return SpeakerTimeline() }
        var turns: [SpeakerTurn] = []
        for (_, speaker) in engine.timeline.speakers {
            for segment in speaker.finalizedSegments {
                let start = Duration.seconds(Double(segment.startTime))
                let end = Duration.seconds(Double(segment.endTime))
                guard end > start else { continue }
                turns.append(SpeakerTurn(speaker: segment.speakerIndex, range: start ..< end))
            }
        }
        return SpeakerTimeline(turns: turns)
    }
}
