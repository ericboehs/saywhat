import Foundation

/// Resolves an observed speaker embedding to an enrolled ``Person`` by cosine
/// similarity — the matching primitive behind persistent speaker identity
/// (DESIGN.md §6). Pure and model-free: the diarization adapter extracts the
/// embeddings, this decides who they are, so the policy is unit-testable without
/// touching CoreML.
///
/// A person is scored by their **best** exemplar (the max over their set), not an
/// average — so a second take of the same voice helps recognition instead of
/// diluting it (docs/speaker-identity-exemplars.md). Speaker embeddings are
/// L2-normalized, so cosine similarity tracks "same voice" well: same speaker
/// scores high (~0.6–0.9), different speakers low. The default threshold is
/// deliberately conservative — across sessions it is far better to mint a new
/// speaker (the user can rename) than to mislabel one person as another.
public struct VoiceprintMatcher: Sendable, Equatable {
    /// Minimum cosine similarity (in `-1...1`) for an embedding to be accepted as
    /// an enrolled speaker. Below it, the embedding is treated as a new speaker.
    public var threshold: Float

    public init(threshold: Float = 0.5) {
        self.threshold = threshold
    }

    /// The enrolled person whose best exemplar is most similar to `embedding`, if
    /// any clears the threshold; otherwise `nil` (a new speaker). Ties keep the
    /// earlier directory entry.
    public func match(_ embedding: [Float], in directory: [EnrolledPerson]) -> Person? {
        bestMatch(embedding, in: directory)?.person
    }

    /// Like ``match(_:in:)`` but also returns the winning cosine similarity, for
    /// callers that need the confidence — e.g. deciding whether fresh evidence is
    /// strong enough to overturn a name already shown to the user. `nil` when no
    /// enrolled person clears the threshold. Ties keep the earlier directory entry.
    public func bestMatch(
        _ embedding: [Float],
        in directory: [EnrolledPerson]
    ) -> (person: Person, score: Float)? {
        var best: (person: Person, score: Float)?
        for enrolled in directory {
            let score = Self.bestSimilarity(embedding, enrolled.exemplars)
            if score > (best?.score ?? -Float.greatestFiniteMagnitude) {
                best = (enrolled.person, score)
            }
        }
        guard let best, best.score >= threshold else { return nil }
        return best
    }

    /// The highest cosine similarity between `embedding` and any of `exemplars`
    /// (a person's best take); the empty set scores no-match.
    public static func bestSimilarity(_ embedding: [Float], _ exemplars: [Voiceprint]) -> Float {
        exemplars.reduce(-Float.greatestFiniteMagnitude) { best, exemplar in
            max(best, cosineSimilarity(embedding, exemplar.embedding))
        }
    }

    /// Cosine similarity of two vectors, in `-1...1`. Mismatched-length or empty
    /// inputs score `0` (no match) rather than trapping — embeddings from
    /// different model versions must never crash the final pass.
    public static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot: Float = 0
        var sumLhs: Float = 0
        var sumRhs: Float = 0
        for (left, right) in zip(lhs, rhs) {
            dot += left * right
            sumLhs += left * left
            sumRhs += right * right
        }
        let magnitude = sumLhs.squareRoot() * sumRhs.squareRoot()
        return magnitude > 0 ? dot / magnitude : 0
    }
}
