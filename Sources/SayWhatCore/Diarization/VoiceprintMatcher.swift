import Foundation

/// Resolves an observed speaker embedding to an enrolled ``Voiceprint`` by cosine
/// similarity — the matching primitive behind persistent speaker identity
/// (DESIGN.md §6). Pure and model-free: the diarization adapter extracts the
/// embeddings, this decides who they are, so the policy is unit-testable without
/// touching CoreML.
///
/// Speaker embeddings are L2-normalized, so cosine similarity tracks "same voice"
/// well: same speaker scores high (~0.6–0.9), different speakers low. The default
/// threshold is deliberately conservative — across sessions it is far better to
/// mint a new speaker (the user can rename) than to mislabel one person as
/// another.
public struct VoiceprintMatcher: Sendable, Equatable {
    /// Minimum cosine similarity (in `-1...1`) for an embedding to be accepted as
    /// an enrolled speaker. Below it, the embedding is treated as a new speaker.
    public var threshold: Float

    public init(threshold: Float = 0.5) {
        self.threshold = threshold
    }

    /// The enrolled voiceprint most similar to `embedding`, if any clears the
    /// threshold; otherwise `nil` (a new speaker). Ties keep the earlier entry.
    public func match(_ embedding: [Float], in directory: [Voiceprint]) -> Voiceprint? {
        var best: Voiceprint?
        var bestScore = -Float.greatestFiniteMagnitude
        for voiceprint in directory {
            let score = Self.cosineSimilarity(embedding, voiceprint.embedding)
            if score > bestScore {
                bestScore = score
                best = voiceprint
            }
        }
        guard let best, bestScore >= threshold else { return nil }
        return best
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
