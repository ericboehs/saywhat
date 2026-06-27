import Foundation

/// Fuses two diarizations of the same track into one: the **turns** (who spoke
/// when, and how many speakers) from one engine, the **voiceprints** from another.
///
/// On real meeting audio the offline pyannote pass under-segments badly — it can
/// glue three speakers into one block — while streaming Sortformer splits the
/// turns cleanly but surfaces no embeddings. So the final pass takes turns from
/// Sortformer and borrows pyannote's per-cluster embeddings for persistent
/// identity, mapping each Sortformer slot to the embedding cluster it overlaps
/// most in time (DESIGN.md §6).
///
/// Best-effort by construction: when pyannote also under-clusters, several
/// Sortformer slots map onto one embedding and identity collapses for those —
/// strictly better than today, where the *whole* track collapses to one speaker.
/// With no embeddings at all the turns pass through unchanged (generic labels).
/// Pure and deterministic; the ML lives behind ``Diarizer``, this is the tested
/// seam where their outputs come together.
public struct SpeakerTimelineFuser: Sendable {
    public init() {}

    /// Combine a `turns` timeline (authoritative segmentation + speaker slots) with
    /// an `embeddingSource` timeline (authoritative voiceprints) into one timeline
    /// carrying `turns`' turns and, per slot, the embedding of the `embeddingSource`
    /// slot it overlaps most. Slots that overlap no embedded cluster are left
    /// unembedded (they fall back to generic labels downstream).
    public func fuse(turns: SpeakerTimeline, embeddingSource: SpeakerTimeline) -> SpeakerTimeline {
        guard !embeddingSource.embeddings.isEmpty else { return turns }

        // For each turns slot, accumulate its temporal overlap with every embedding
        // cluster, then keep the embedding of whichever cluster it overlaps most.
        var overlap: [Int: [Int: Double]] = [:]
        for turn in turns.turns {
            for source in embeddingSource.turns {
                guard embeddingSource.embeddings[source.speaker] != nil else { continue }
                let seconds = turn.range.overlap(with: source.range)
                guard seconds > 0 else { continue }
                overlap[turn.speaker, default: [:]][source.speaker, default: 0] += seconds
            }
        }

        var embeddings: [Int: [Float]] = [:]
        for slot in Set(turns.turns.map(\.speaker)) {
            guard let best = overlap[slot]?.max(by: { $0.value < $1.value })?.key,
                  let embedding = embeddingSource.embeddings[best]
            else { continue }
            embeddings[slot] = embedding
        }
        return SpeakerTimeline(turns: turns.turns, embeddings: embeddings)
    }
}
