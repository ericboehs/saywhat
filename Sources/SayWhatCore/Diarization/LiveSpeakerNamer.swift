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

    /// Recent system audio, trimmed to `window` so a long meeting stays bounded.
    private var frames: [AudioFrame] = []
    /// The latest remote-speaker split from the live diarizer.
    private var timeline = SpeakerTimeline()
    /// End of the newest audio seen, the anchor the rolling window trims against.
    private var latest: Duration = .zero
    /// Slot → resolved name. Sticky: once a slot is confidently named it keeps
    /// that name for the meeting rather than flickering as later audio drifts.
    private var names: [Int: String] = [:]

    /// - Parameters:
    ///   - matcher: the cosine-similarity policy; share the final pass's so the
    ///     live and final notions of "same voice" agree.
    ///   - minSpeech: how much of a slot's audio must accumulate before we trust
    ///     an identity from it. Short interjections don't carry a stable vector.
    ///   - window: how much recent audio to retain — enough to gather `minSpeech`
    ///     for a slot that has been talking, bounded so memory doesn't grow.
    public init(
        embedder: any SpeakerEmbedder,
        store: VoiceprintStore?,
        matcher: VoiceprintMatcher = VoiceprintMatcher(),
        minSpeech: Duration = .seconds(3),
        window: Duration = .seconds(30)
    ) {
        self.embedder = embedder
        self.store = store
        self.matcher = matcher
        self.window = window
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

    /// Try to name any still-unnamed slot that has accumulated enough audio, and
    /// return the full sticky slot → name map. Only slots whose voice clears the
    /// matcher against an enrolled voiceprint get a name; unknown voices stay
    /// generic (the final pass will mint them later). Throttle the caller — each
    /// unresolved slot costs one embedding inference.
    public func resolve() async -> [Int: String] {
        guard let store, let directory = try? store.all(), !directory.isEmpty else {
            return names
        }
        let unnamed = Set(timeline.turns.map(\.speaker)).subtracting(names.keys).sorted()
        for slot in unnamed {
            let samples = SpeakerAudio.samples(forSlot: slot, in: timeline, from: frames)
            guard samples.count >= minSamples else { continue }
            guard let vector = try? await embedder.embedding(for: samples) else { continue }
            if let match = matcher.match(vector, in: directory) {
                names[slot] = match.name
            }
        }
        return names
    }
}
