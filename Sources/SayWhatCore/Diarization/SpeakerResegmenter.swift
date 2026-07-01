import Foundation

/// Re-segments a diarized timeline by **identity** instead of trusting the
/// diarizer's own speaker slots. On real meetings Sortformer can fuse two voices
/// into one slot (Theo and MKBHD both landed in "Speaker 1" — see
/// docs/speaker-identity-resegmentation.md); since everything downstream is
/// slot-granular, that one slot then gets a single blended voiceprint and a
/// single rename, so neither identity nor the user can pull the two apart.
///
/// The fix re-clusters the *turns* by their own `wespeaker_v2` embeddings — the
/// same space ``VoiceprintMatcher`` already trusts — and lets those clusters, not
/// the diarizer's slots, define who's who. Theo's turns cluster together and
/// MKBHD's cluster together even though Sortformer called them all slot 1.
///
/// Pure and model-free: the embedding per turn is supplied by the caller (the
/// final pass runs the model), so the clustering, group→identity resolution, and
/// short-turn assignment are all unit-testable without CoreML. The diarizer's turn
/// *boundaries* are kept; only its speaker *labels* are overridden.
public struct SpeakerResegmenter: Sendable {
    /// The group→identity policy; its matcher's threshold also governs clustering,
    /// so one fuzziness setting decides both "same voice for clustering" and "same
    /// voice for enrollment" (docs/speaker-identity-resegmentation.md, D2).
    public var resolver: SpeakerResolver

    public init(resolver: SpeakerResolver = SpeakerResolver()) {
        self.resolver = resolver
    }

    /// A re-segmented timeline whose turns are keyed by identity **group** instead
    /// of diarizer slot, plus how each group resolved (matched person or mint).
    public struct Resegmentation: Sendable, Equatable {
        /// The original turns, re-labeled so `speaker` is the identity group id.
        public let timeline: SpeakerTimeline
        /// Group id → how that voice resolved. Empty when nothing was embeddable.
        public let speakers: [Int: ResolvedSpeaker]

        public init(timeline: SpeakerTimeline, speakers: [Int: ResolvedSpeaker]) {
            self.timeline = timeline
            self.speakers = speakers
        }
    }

    /// Re-segment `turns` by voice.
    ///
    /// - Parameters:
    ///   - turns: the diarizer's turns (boundaries are kept; labels are replaced).
    ///   - embeddings: identity vector per **turn index** (into `turns`). A turn
    ///     too short/silent to embed is simply absent — it is attached to a
    ///     neighbor's group in step 3.
    ///   - directory: the enrolled persons to resolve groups against.
    ///   - mintName: name for a group matching nobody (default `Speaker N`).
    /// - Returns: turns re-keyed by identity group, and each group's resolution.
    ///   When no turn was embeddable, the diarizer's own segmentation passes
    ///   through unchanged and `speakers` is empty (the caller falls back to
    ///   generic labels).
    public func resegment(
        turns: [SpeakerTurn],
        embeddings: [Int: [Float]],
        against directory: [EnrolledPerson],
        mintName: (Int) -> String = { "Speaker \($0)" }
    ) -> Resegmentation {
        let embedded = embeddings.keys.sorted()
        guard !embedded.isEmpty else {
            return Resegmentation(timeline: SpeakerTimeline(turns: turns), speakers: [:])
        }

        // 1. Group the embeddable turns by voice. Each turn that matches an
        //    enrolled person is anchored to that person's group; turns matching
        //    nobody are clustered among themselves to discover unknown speakers.
        //
        //    Anchoring on the enrolled exemplars — not turn-to-turn similarity — is
        //    what keeps one known voice together. A short turn's own embedding is
        //    noisy: two genuine Zwag turns can each clear the threshold against
        //    Zwag's clean exemplars yet sit below it *relative to each other*, so
        //    pure agglomerative clustering shattered Zwag across many "Speaker N"
        //    groups (docs/speaker-identity-resegmentation.md, D5). Identity is the
        //    stable anchor; mutual similarity only has to separate the unknowns.
        let matcher = resolver.matcher
        var byPerson: [UUID: [Int]] = [:]
        var personOrder: [UUID] = []
        var unknown: [Int] = []
        for turn in embedded {
            if let person = matcher.match(embeddings[turn] ?? [], in: directory) {
                if byPerson[person.id] == nil { personOrder.append(person.id) }
                byPerson[person.id, default: []].append(turn)
            } else {
                unknown.append(turn)
            }
        }
        let knownGroups = personOrder.map { byPerson[$0] ?? [] }

        // 2. Order all groups by their earliest turn so group ids (and thus
        //    "Speaker N" numbering) follow the transcript's reading order.
        let groups = (knownGroups + cluster(unknown, embeddings))
            .sorted { orderKey($0, turns) < orderKey($1, turns) }

        var groupOfTurn: [Int: Int] = [:]
        for (id, group) in groups.enumerated() {
            for turnIndex in group {
                groupOfTurn[turnIndex] = id
            }
        }

        // 3. Attach each short/unembeddable turn to the group of the embedded turn
        //    nearest it in time. We deliberately ignore the diarizer's own slot
        //    here: its slot assignment is the very thing this pass distrusts (it
        //    fuses voices), so temporal adjacency is the more reliable prior
        //    (docs/speaker-identity-resegmentation.md, D3).
        for index in turns.indices where groupOfTurn[index] == nil {
            if let neighbor = nearest(to: turns[index].range, among: embedded, in: turns) {
                groupOfTurn[index] = groupOfTurn[neighbor]
            }
        }

        // 4. Resolve each group to an identity via its medoid — a real take central
        //    to the group, never an average (averaging would dilute the voiceprint).
        var observations: [Int: [Float]] = [:]
        for (id, group) in groups.enumerated() {
            observations[id] = medoid(group, embeddings)
        }
        let resolution = resolver.resolve(observations, against: directory, mintName: mintName)

        // 5. Re-key every turn to its group id (boundaries unchanged).
        let rekeyed = turns.indices.map { index in
            SpeakerTurn(
                speaker: groupOfTurn[index] ?? turns[index].speaker,
                range: turns[index].range
            )
        }
        return Resegmentation(
            timeline: SpeakerTimeline(turns: rekeyed),
            speakers: resolution.bySlot
        )
    }

    // MARK: clustering

    /// Agglomerative average-linkage clustering of the embedded turns: repeatedly
    /// merge the two most-similar groups while their average cross-pair cosine
    /// clears the matcher threshold. Deterministic — the lowest-index best pair is
    /// merged first, so the result never depends on dictionary order.
    ///
    /// Cross-group cosine **sums** are kept in a matrix and updated by the
    /// Lance-Williams recurrence — `sum(i∪j, k) = sum(i, k) + sum(j, k)`, with the
    /// mean each comparison needs being `sum / (|i|·|j|)`. That is the identical
    /// average-linkage result as re-averaging every pair, but the pairwise cosines
    /// are computed once up front rather than on every merge: a long meeting where
    /// nobody is enrolled (every turn "unknown") used to spend minutes here, frozen
    /// at "Identifying… 100%", because each merge re-summed all O(n²) pairs.
    private func cluster(_ indices: [Int], _ embeddings: [Int: [Float]]) -> [[Int]] {
        var groups = indices.map { [$0] }
        guard groups.count > 1 else { return groups }
        let threshold = resolver.matcher.threshold
        var sums = groups.indices.map { left in
            groups.indices.map { right in
                VoiceprintMatcher.cosineSimilarity(
                    embeddings[groups[left][0]] ?? [],
                    embeddings[groups[right][0]] ?? []
                )
            }
        }
        while groups.count > 1 {
            var bestSimilarity = -Float.greatestFiniteMagnitude
            var bestPair: (left: Int, right: Int)?
            for left in groups.indices {
                for right in (left + 1) ..< groups.count {
                    let mean = sums[left][right] / Float(groups[left].count * groups[right].count)
                    if mean > bestSimilarity {
                        bestSimilarity = mean
                        bestPair = (left, right)
                    }
                }
            }
            guard let pair = bestPair, bestSimilarity >= threshold else { break }
            let (left, right) = (pair.left, pair.right)
            for other in groups.indices where other != left && other != right {
                sums[left][other] += sums[right][other]
                sums[other][left] = sums[left][other]
            }
            groups[left].append(contentsOf: groups[right])
            groups.remove(at: right)
            sums.remove(at: right)
            for row in sums.indices {
                sums[row].remove(at: right)
            }
        }
        return groups
    }

    /// The group's medoid embedding — the member most similar to the rest (itself
    /// for a singleton). A representative real take, so resolution and the rename
    /// path bind to genuine audio rather than a synthetic centroid.
    private func medoid(_ group: [Int], _ embeddings: [Int: [Float]]) -> [Float] {
        guard group.count > 1 else { return embeddings[group.first ?? -1] ?? [] }
        var best = group[0]
        var bestScore = -Float.greatestFiniteMagnitude
        for candidate in group {
            var score: Float = 0
            for other in group where other != candidate {
                score += VoiceprintMatcher.cosineSimilarity(
                    embeddings[candidate] ?? [],
                    embeddings[other] ?? []
                )
            }
            if score > bestScore {
                bestScore = score
                best = candidate
            }
        }
        return embeddings[best] ?? []
    }

    // MARK: short-turn assignment

    /// The candidate turn with the smallest time gap to `target` (ties by index).
    private func nearest(
        to target: Range<Duration>,
        among candidates: [Int],
        in turns: [SpeakerTurn]
    ) -> Int? {
        candidates.min { lhs, rhs in
            let gapLhs = gap(target, turns[lhs].range)
            let gapRhs = gap(target, turns[rhs].range)
            if gapLhs != gapRhs { return gapLhs < gapRhs }
            return lhs < rhs
        }
    }

    /// Seconds between two ranges (0 if they overlap or touch).
    private func gap(_ lhs: Range<Duration>, _ rhs: Range<Duration>) -> Double {
        if lhs.overlap(with: rhs) > 0 { return 0 }
        if lhs.upperBound <= rhs.lowerBound { return (rhs.lowerBound - lhs.upperBound).seconds }
        return (lhs.lowerBound - rhs.upperBound).seconds
    }

    // MARK: ordering

    /// Sort key for a group: its earliest turn start, then its lowest turn index —
    /// so groups are numbered in the order their voices first appear.
    private func orderKey(_ group: [Int], _ turns: [SpeakerTurn]) -> Duration {
        group.map { turns[$0].range.lowerBound }.min() ?? .zero
    }
}
