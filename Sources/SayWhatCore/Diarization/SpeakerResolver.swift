import Foundation

/// How one diarized remote slot resolved: either to an enrolled ``Person``, or to
/// a fresh, un-named mint awaiting a name. Either way it carries this slot's own
/// embedding as a ``Voiceprint`` exemplar, so naming the slot can bind that take
/// to a person (the rename path), and the display ``name`` the merge should show.
public struct ResolvedSpeaker: Sendable, Equatable, Codable {
    /// The enrolled identity this slot matched, or `nil` for an un-named mint.
    public let person: Person?

    /// This slot's observed embedding as an exemplar. For a match, its `personID`
    /// is already the matched person's; for a mint it is un-owned (`nil`) and not
    /// persisted until the user names the slot.
    public let exemplar: Voiceprint

    /// What to label this slot in the transcript: the person's name, or a generic
    /// `Speaker N` for an un-named mint.
    public let name: String

    public init(person: Person?, exemplar: Voiceprint, name: String) {
        self.person = person
        self.exemplar = exemplar
        self.name = name
    }
}

/// The outcome of resolving a session's remote speaker slots to identities: how
/// each slot resolved (matched person or fresh mint). Unlike the prior design,
/// mints are **not** persisted here — an un-named mint stays in memory until the
/// user names it, so the directory never fills with orphan `Speaker N` rows
/// (docs/speaker-identity-exemplars.md).
public struct SpeakerResolution: Sendable, Equatable {
    /// Diarizer slot index → how it resolved.
    public let bySlot: [Int: ResolvedSpeaker]

    public init(bySlot: [Int: ResolvedSpeaker]) {
        self.bySlot = bySlot
    }
}

/// Maps the diarizer's per-session speaker slots onto persistent ``Person``
/// identities — the step that turns "remote slot 1 in *this* meeting" into "Eric,
/// the same person as last meeting" (DESIGN.md §6).
///
/// Pure and model-free: the diarization adapter extracts one embedding per slot,
/// this decides who each is, so the assignment policy is unit-testable without
/// CoreML. Resolution is **greedy and mutually exclusive** — the highest-scoring
/// (slot, person) pairs are taken first, and neither a slot nor a person is used
/// twice, so two people in one meeting can't collapse onto a single identity. A
/// person is scored by their best exemplar. Any slot left unmatched mints a fresh,
/// un-named speaker the user can later name.
public struct SpeakerResolver: Sendable {
    /// The similarity policy used to accept a slot↔person pairing.
    public var matcher: VoiceprintMatcher

    public init(matcher: VoiceprintMatcher = VoiceprintMatcher()) {
        self.matcher = matcher
    }

    /// Resolve each observed slot embedding to an enrolled person or a fresh mint.
    ///
    /// - Parameters:
    ///   - observations: slot index → that slot's observed 256-dim embedding.
    ///   - directory: the enrolled persons (with their exemplars) to match against.
    ///   - mintName: name for an unmatched slot, given a directory-unique number
    ///     (default `Speaker N`). The number is the smallest positive integer not
    ///     already taken by an enrolled `Speaker N` name, so an auto-named newcomer
    ///     never duplicates one that already exists.
    public func resolve(
        _ observations: [Int: [Float]],
        against directory: [EnrolledPerson],
        mintName: (Int) -> String = { "Speaker \($0)" }
    ) -> SpeakerResolution {
        let candidates = rankedCandidates(observations, directory)

        var personBySlot: [Int: Person] = [:]
        var claimed: Set<UUID> = []
        for candidate in candidates {
            guard personBySlot[candidate.slot] == nil, !claimed.contains(candidate.person.id) else {
                continue
            }
            personBySlot[candidate.slot] = candidate.person
            claimed.insert(candidate.person.id)
        }

        // Walk slots in order so assignment is deterministic. Matched slots take
        // the person's name; the rest mint a fresh un-named speaker, numbered with
        // the next directory-unique "Speaker N".
        var usedNumbers = Set(directory.compactMap { Self.speakerNumber($0.person.name) })
        var bySlot: [Int: ResolvedSpeaker] = [:]
        for slot in observations.keys.sorted() {
            guard let embedding = observations[slot] else { continue }
            if let person = personBySlot[slot] {
                bySlot[slot] = ResolvedSpeaker(
                    person: person,
                    exemplar: Voiceprint(personID: person.id, embedding: embedding),
                    name: person.name
                )
            } else {
                let number = Self.nextFreeNumber(&usedNumbers)
                bySlot[slot] = ResolvedSpeaker(
                    person: nil,
                    exemplar: Voiceprint(embedding: embedding),
                    name: mintName(number)
                )
            }
        }

        return SpeakerResolution(bySlot: bySlot)
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

    /// One acceptable (slot, person) pairing and its similarity.
    private struct Candidate {
        let slot: Int
        let person: Person
        let score: Float
        let directoryIndex: Int
    }

    /// All slot↔person pairings that clear the threshold, best first. Ties break
    /// deterministically (lower slot, then earlier directory entry) so the greedy
    /// assignment never depends on dictionary iteration order.
    private func rankedCandidates(
        _ observations: [Int: [Float]],
        _ directory: [EnrolledPerson]
    ) -> [Candidate] {
        var candidates: [Candidate] = []
        for slot in observations.keys.sorted() {
            guard let embedding = observations[slot] else { continue }
            for (index, enrolled) in directory.enumerated() {
                let score = VoiceprintMatcher.bestSimilarity(embedding, enrolled.exemplars)
                if score >= matcher.threshold {
                    candidates.append(Candidate(
                        slot: slot,
                        person: enrolled.person,
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
