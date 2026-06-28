import FluidAudio
import Foundation
import os

/// The concrete ``SpeakerEmbedder``, backed by FluidAudio's `wespeaker_v2` model
/// (the online `DiarizerManager`'s `extractSpeakerEmbedding`). This is the one
/// identity space persistent recognition runs in — used by the final pass when it
/// mints/looks up a voiceprint **and** by the live ``LiveSpeakerNamer`` so a name
/// learned in one is recognized by the other (DESIGN.md §6).
///
/// Deliberately a *different* model from anything a ``Diarizer`` uses to cluster
/// turns: Sortformer (live) emits no identity vectors at all, and offline pyannote
/// clusters in its own incomparable space. Re-embedding a slot's audio here with a
/// purpose-built speaker-ID model is what makes a voiceprint portable.
///
/// An actor so the loaded CoreML manager is built once and cached across calls
/// under one isolation domain; the non-Sendable `DiarizerManager` is created and
/// used entirely inside this actor, never shared. Models download once from
/// HuggingFace to Application Support; nothing else touches the network.
///
/// Hardware/ML adapter (coverage-excluded): the contract it satisfies is exercised
/// through ``SpeakerEmbedder`` fakes, its accuracy is a golden-file concern, and
/// the slot-slicing it feeds on lives in the tested ``SpeakerAudio``. See
/// QUALITY.md §6.
public actor WeSpeakerEmbedder: SpeakerEmbedder {
    private static let log = Logger(subsystem: "com.boehs.saywhat", category: "diarize.wespeaker")

    /// Below this the WeSpeaker model has too little speech for a stable vector;
    /// treat it as "not ready" (`nil`) rather than embedding noise. One second at
    /// the model's 16 kHz rate.
    private static let minSamples = 16000

    private var manager: DiarizerManager?

    public init() {}

    public func embedding(for samples: [Float]) async throws -> [Float]? {
        guard samples.count >= Self.minSamples else { return nil }
        let manager = try await loadedManager()
        return try manager.extractSpeakerEmbedding(from: samples)
    }

    /// Load (downloading + compiling on first use) and cache the diarizer models,
    /// of which only the WeSpeaker embedding model is used here. The manager is
    /// reused across calls so the model stays warm for the whole session.
    private func loadedManager() async throws -> DiarizerManager {
        if let manager { return manager }
        let models = try await DiarizerModels.download()
        let manager = DiarizerManager()
        manager.initialize(models: consume models)
        self.manager = manager
        Self.log.info("WeSpeaker identity embedder ready")
        return manager
    }
}
