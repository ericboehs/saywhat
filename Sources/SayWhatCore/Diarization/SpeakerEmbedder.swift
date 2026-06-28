import Foundation

/// Extracts a speaker-**identity** embedding from a clip of one voice — the
/// vector that persistent recognition matches across meetings (DESIGN.md §6).
///
/// This is the single identity space shared by **both** the live namer and the
/// final pass: a voice enrolled by one is recognized by the other only because
/// they embed with the same model. The concrete adapter (FluidAudio's
/// `wespeaker_v2`) lives behind this protocol so the matching policy stays pure
/// and model-free — the adapter turns audio into a vector, ``VoiceprintMatcher``
/// decides whose it is.
///
/// Identity embedding is deliberately decoupled from whatever a ``Diarizer`` uses
/// internally to *cluster* turns: Sortformer and offline pyannote each have their
/// own embedding spaces for splitting speakers, neither of which is comparable to
/// a stored voiceprint. Re-extracting a dedicated identity vector here is what
/// makes a voiceprint portable between the live and final paths.
public protocol SpeakerEmbedder: Sendable {
    /// A 256-dim, L2-normalized identity embedding for `samples` (mono 16 kHz,
    /// the model's rate), or `nil` when the clip is too short/silent to embed.
    /// Implementations must not throw on ordinary "not enough audio" — that is a
    /// `nil`, not an error — so a caller can simply skip an unready slot.
    func embedding(for samples: [Float]) async throws -> [Float]?
}

/// Assembles the audio belonging to one diarizer slot — the samples from `frames`
/// that fall within that slot's turns on a ``SpeakerTimeline``. The identity
/// embedder needs a single contiguous clip per speaker; this gathers it. Pure and
/// model-free so both the live namer and the final pass slice the same way.
public enum SpeakerAudio {
    /// The concatenated samples of `frames` whose time span overlaps any turn the
    /// `slot` holds on `timeline`. Frame-level granularity (a frame is included
    /// whole when it overlaps): frames are short relative to a turn, so this keeps
    /// the slicer simple and robust without meaningfully diluting the clip.
    public static func samples(
        forSlot slot: Int,
        in timeline: SpeakerTimeline,
        from frames: [AudioFrame]
    ) -> [Float] {
        let ranges = timeline.turns.filter { $0.speaker == slot }.map(\.range)
        guard !ranges.isEmpty else { return [] }
        var gathered: [Float] = []
        for frame in frames {
            let frameRange = frame.startOffset ..< (frame.startOffset + frame.duration)
            if ranges.contains(where: { frameRange.overlap(with: $0) > 0 }) {
                gathered.append(contentsOf: frame.samples)
            }
        }
        return gathered
    }
}
