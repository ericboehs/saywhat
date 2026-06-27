import Foundation

/// The outcome of resolving a session's remote speaker slots to persistent
/// identities: which ``Voiceprint`` each slot is, and which of those were newly
/// minted (and so need persisting to the ``VoiceprintStore``).
public struct SpeakerResolution: Sendable, Equatable {
    /// Diarizer slot index → the voiceprint it resolved to.
    public let bySlot: [Int: Voiceprint]

    /// Voiceprints created this session for slots that matched nobody enrolled.
    /// A subset of `bySlot`'s values; persist these so the speaker is recognized
    /// next time.
    public let minted: [Voiceprint]

    public init(bySlot: [Int: Voiceprint], minted: [Voiceprint]) {
        self.bySlot = bySlot
        self.minted = minted
    }
}

/// Maps the diarizer's per-session speaker slots onto persistent ``Voiceprint``
/// identities — the step that turns "remote slot 1 in *this* meeting" into "Eric,
/// the same person as last meeting" (DESIGN.md §6).
///
/// Pure and model-free: the diarization adapter extracts one embedding per slot,
/// this decides who each is, so the assignment policy is unit-testable without
/// CoreML. Resolution is **greedy and mutually exclusive** — the highest-scoring
/// (slot, enrolled-speaker) pairs are taken first, and neither a slot nor an
/// enrolled voiceprint is used twice, so two people in one meeting can't collapse
/// onto a single identity. Any slot left unmatched mints a fresh voiceprint the
/// user can later name.
public struct SpeakerResolver: Sendable {
    /// The similarity policy used to accept a slot↔enrolled-speaker pairing.
    public var matcher: VoiceprintMatcher

    public init(matcher: VoiceprintMatcher = VoiceprintMatcher()) {
        self.matcher = matcher
    }

    /// Resolve each observed slot embedding to an enrolled or freshly minted
    /// voiceprint.
    ///
    /// - Parameters:
    ///   - observations: slot index → that slot's observed 256-dim embedding.
    ///   - directory: the enrolled voiceprints to match against.
    ///   - mintName: name for a new speaker, given a directory-unique number
    ///     (default `Speaker N`). The number is the smallest positive integer not
    ///     already taken by an enrolled `Speaker N`, so an auto-named newcomer
    ///     never duplicates a name that already exists.
    public func resolve(
        _ observations: [Int: [Float]],
        against directory: [Voiceprint],
        mintName: (Int) -> String = { "Speaker \($0)" }
    ) -> SpeakerResolution {
        let candidates = rankedCandidates(observations, directory)

        var bySlot: [Int: Voiceprint] = [:]
        var claimed: Set<UUID> = []
        for candidate in candidates {
            guard bySlot[candidate.slot] == nil, !claimed.contains(candidate.voiceprint.id) else {
                continue
            }
            bySlot[candidate.slot] = candidate.voiceprint
            claimed.insert(candidate.voiceprint.id)
        }

        // Mint a new voiceprint for every slot nobody enrolled claimed, in slot
        // order so the assignment is deterministic. Each auto name takes the next
        // directory-unique "Speaker N" — previously the number came from the
        // per-meeting slot, so every meeting's first newcomer became "Speaker 1".
        var usedNumbers = Set(directory.compactMap { Self.speakerNumber($0.name) })
        var minted: [Voiceprint] = []
        for slot in observations.keys.sorted() {
            guard bySlot[slot] == nil, let embedding = observations[slot] else { continue }
            let number = Self.nextFreeNumber(&usedNumbers)
            let fresh = Voiceprint(name: mintName(number), embedding: embedding)
            bySlot[slot] = fresh
            minted.append(fresh)
        }

        return SpeakerResolution(bySlot: bySlot, minted: minted)
    }

    /// The `N` in an auto-generated `Speaker N` name, or `nil` for a custom name.
    private static func speakerNumber(_ name: String) -> Int? {
        let prefix = "Speaker "
        guard name.hasPrefix(prefix) else { return nil }
        return Int(name.dropFirst(prefix.count))
    }

    /// The smallest positive integer not in `used`, claiming it so a run of mints
    /// gets distinct numbers.
    private static func nextFreeNumber(_ used: inout Set<Int>) -> Int {
        var number = 1
        while used.contains(number) {
            number += 1
        }
        used.insert(number)
        return number
    }

    /// One acceptable (slot, enrolled-speaker) pairing and its similarity.
    private struct Candidate {
        let slot: Int
        let voiceprint: Voiceprint
        let score: Float
        let directoryIndex: Int
    }

    /// All slot↔enrolled pairings that clear the threshold, best first. Ties break
    /// deterministically (lower slot, then earlier directory entry) so the greedy
    /// assignment never depends on dictionary iteration order.
    private func rankedCandidates(
        _ observations: [Int: [Float]],
        _ directory: [Voiceprint]
    ) -> [Candidate] {
        var candidates: [Candidate] = []
        for slot in observations.keys.sorted() {
            guard let embedding = observations[slot] else { continue }
            for (index, voiceprint) in directory.enumerated() {
                let score = VoiceprintMatcher.cosineSimilarity(embedding, voiceprint.embedding)
                if score >= matcher.threshold {
                    candidates.append(Candidate(
                        slot: slot,
                        voiceprint: voiceprint,
                        score: score,
                        directoryIndex: index
                    ))
                }
            }
        }
        return candidates.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.slot != rhs.slot { return lhs.slot < rhs.slot }
            return lhs.directoryIndex < rhs.directoryIndex
        }
    }
}
