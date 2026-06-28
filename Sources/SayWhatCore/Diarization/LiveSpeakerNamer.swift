import Foundation

/// Names remote speakers **during** a meeting by matching their voice to enrolled
/// voiceprints in real time — so a recurring participant shows up as "Eric"
/// instead of "Speaker 2" while the meeting is still going (DESIGN.md §6).
///
/// Purely additive to the live diarization path: Sortformer still splits the
/// system track into slots; this only attaches a *name* to a slot once it has
/// heard enough of that voice. It is deliberately **read-only** against the
/// store — it never mints or persists a voiceprint. Minting is the final pass's
/// job (it has the whole meeting and the authoritative diarization); doing it live
/// would race that and risk polluting the directory with half-formed vectors.
///
/// Identity runs in the same `wespeaker_v2` space the final pass persists, via the
/// injected ``SpeakerEmbedder`` — that shared space is the whole reason a name
/// learned by one pass is recognized by the other.
///
/// An actor: the capture loop feeds it audio and the diarizer feeds it timelines
/// from different tasks, and ``resolve()`` reads both. The embedding model lives
/// behind ``SpeakerEmbedder``, so the namer's policy (window, floors, stickiness)
/// is unit-testable with a fake.
public actor LiveSpeakerNamer {
    private let embedder: any SpeakerEmbedder
    private let store: VoiceprintStore?
    private let matcher: VoiceprintMatcher
    private let window: Duration
    private let minSamples: Int
    private let correctionMargin: Float

    /// Recent system audio, trimmed to `window` so a long meeting stays bounded.
    private var frames: [AudioFrame] = []
    /// The latest remote-speaker split from the live diarizer.
    private var timeline = SpeakerTimeline()
    /// End of the newest audio seen, the anchor the rolling window trims against.
    private var latest: Duration = .zero
    /// Slot → resolved name. Re-evaluated as more of a slot's audio accumulates,
    /// but only relabeled when a different enrolled voice is a clearly better match
    /// (see ``correctionMargin``) — so a confident name doesn't flicker, yet a wrong
    /// early match self-corrects instead of sticking for the whole meeting.
    private var names: [Int: String] = [:]
    /// Slot → the last evaluation's diagnostics (nearest enrolled voice, its score,
    /// how much audio has accumulated), for the debug overlay. Purely observational
    /// — it never influences naming.
    private var diagnostics: [Int: SlotDiagnostics] = [:]

    /// What the namer saw for one slot on its most recent evaluation. `nearestName`
    /// is the closest enrolled voice *regardless of threshold*, so the overlay can
    /// show a near-miss; `samples` against the floor reveals a slot still gathering
    /// audio.
    public struct SlotDiagnostics: Sendable, Equatable {
        public let nearestName: String?
        public let score: Float
        public let samples: Int
        public let minSamples: Int
    }

    /// - Parameters:
    ///   - matcher: the cosine-similarity policy; share the final pass's so the
    ///     live and final notions of "same voice" agree.
    ///   - minSpeech: how much of a slot's audio must accumulate before we trust
    ///     an identity from it. Short interjections don't carry a stable vector.
    ///   - window: how much recent audio to retain — enough to gather `minSpeech`
    ///     for a slot that has been talking, bounded so memory doesn't grow.
    ///   - correctionMargin: how much more similar a *different* enrolled voice must
    ///     be than the name already shown before the slot is relabeled. Small enough
    ///     that a wrong early lock-in is corrected once cleaner audio arrives, large
    ///     enough that a confident name doesn't flicker between two close voices.
    public init(
        embedder: any SpeakerEmbedder,
        store: VoiceprintStore?,
        matcher: VoiceprintMatcher = VoiceprintMatcher(),
        minSpeech: Duration = .seconds(3),
        window: Duration = .seconds(30),
        correctionMargin: Float = 0.1
    ) {
        self.embedder = embedder
        self.store = store
        self.matcher = matcher
        self.window = window
        self.correctionMargin = correctionMargin
        minSamples = Int(minSpeech.seconds * Double(AudioStreamFormat.model.sampleRate))
    }

    /// Take one system-track frame, dropping audio older than `window`.
    public func ingest(_ frame: AudioFrame) {
        frames.append(frame)
        latest = Swift.max(latest, frame.startOffset + frame.duration)
        let cutoff = latest - window
        if cutoff > .zero {
            frames.removeAll { $0.startOffset + $0.duration <= cutoff }
        }
    }

    /// Adopt the diarizer's latest remote-speaker split.
    public func update(_ timeline: SpeakerTimeline) {
        self.timeline = timeline
    }

    /// Re-evaluate every slot that has accumulated enough audio and return the full
    /// slot → name map. A slot whose voice clears the matcher against an enrolled
    /// person gets that name; an unnamed slot whose voice matches nobody stays
    /// generic (the final pass labels it later). A slot that is **already** named is
    /// only relabeled when a different enrolled voice beats the shown name by
    /// ``correctionMargin`` on the current audio — correcting a wrong early match
    /// without flickering. Throttle the caller — each slot costs one embedding
    /// inference per call.
    public func resolve() async -> [Int: String] {
        guard let store, let directory = try? store.enrolledPersons(), !directory.isEmpty else {
            return names
        }
        for slot in Set(timeline.turns.map(\.speaker)).sorted() {
            let samples = SpeakerAudio.samples(forSlot: slot, in: timeline, from: frames)
            guard samples.count >= minSamples else {
                diagnostics[slot] = SlotDiagnostics(
                    nearestName: nil, score: 0, samples: samples.count, minSamples: minSamples
                )
                continue
            }
            guard let vector = try? await embedder.embedding(for: samples) else { continue }
            let nearest = matcher.nearest(vector, in: directory)
            diagnostics[slot] = SlotDiagnostics(
                nearestName: nearest?.person.name,
                score: nearest?.score ?? 0,
                samples: samples.count,
                minSamples: minSamples
            )
            if let match = matcher.bestMatch(vector, in: directory) {
                names[slot] = name(forSlot: slot, winner: match, vector: vector, in: directory)
            }
        }
        return names
    }

    /// The latest per-slot diagnostics for the debug overlay — what the namer saw
    /// last time it evaluated each slot. Observational only.
    public func debug() -> [Int: SlotDiagnostics] {
        diagnostics
    }

    /// The name to record for `slot`: the winning match normally, but an existing
    /// different name is kept unless the winner clears it by ``correctionMargin`` on
    /// this same audio — so a confident identity stays put while a clearly-wrong
    /// early lock-in is overturned as more of the voice is heard.
    private func name(
        forSlot slot: Int,
        winner: (person: Person, score: Float),
        vector: [Float],
        in directory: [EnrolledPerson]
    ) -> String {
        guard let current = names[slot], current != winner.person.name else {
            return winner.person.name
        }
        let incumbent = directory.first { $0.person.name == current }
            .map { VoiceprintMatcher.bestSimilarity(vector, $0.exemplars) }
            ?? -Float.greatestFiniteMagnitude
        return winner.score >= incumbent + correctionMargin ? winner.person.name : current
    }
}
