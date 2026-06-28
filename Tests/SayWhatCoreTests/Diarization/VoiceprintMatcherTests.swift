import Foundation
import Testing
@testable import SayWhatCore

@Suite("VoiceprintMatcher")
struct VoiceprintMatcherTests {
    /// An enrolled person whose exemplars are the given embeddings.
    private func enrolled(_ name: String, _ embeddings: [Float]...) -> EnrolledPerson {
        let person = Person(name: name)
        return EnrolledPerson(
            person: person,
            exemplars: embeddings.map { Voiceprint(personID: person.id, embedding: $0) }
        )
    }

    // MARK: cosine similarity

    @Test("identical vectors score 1, orthogonal 0, opposite -1")
    func cosineExtremes() {
        #expect(VoiceprintMatcher.cosineSimilarity([1, 0, 0], [1, 0, 0]) == 1)
        #expect(VoiceprintMatcher.cosineSimilarity([1, 0, 0], [0, 1, 0]) == 0)
        #expect(VoiceprintMatcher.cosineSimilarity([1, 0, 0], [-1, 0, 0]) == -1)
    }

    @Test("magnitude doesn't matter — only direction")
    func cosineScaleInvariant() {
        #expect(VoiceprintMatcher.cosineSimilarity([2, 0], [9, 0]) == 1)
    }

    @Test("mismatched-length or empty inputs score 0 instead of trapping")
    func cosineDegenerate() {
        #expect(VoiceprintMatcher.cosineSimilarity([1, 0], [1, 0, 0]) == 0)
        #expect(VoiceprintMatcher.cosineSimilarity([], []) == 0)
        #expect(VoiceprintMatcher.cosineSimilarity([0, 0], [1, 0]) == 0)
    }

    // MARK: match

    @Test("returns the closest enrolled person above threshold")
    func matchesClosest() {
        let directory = [
            enrolled("Eric", [1, 0, 0]),
            enrolled("Ashley", [0, 1, 0]),
        ]
        #expect(VoiceprintMatcher().match([0.9, 0.1, 0], in: directory)?.name == "Eric")
        #expect(VoiceprintMatcher().match([0.1, 0.95, 0], in: directory)?.name == "Ashley")
    }

    @Test("a person is scored by their best exemplar, not an average")
    func scoresBestExemplar() {
        // Eric's second take points away from the query; his first matches it
        // exactly. The best (not the mean) is what counts.
        let directory = [enrolled("Eric", [1, 0], [0, 1])]
        #expect(VoiceprintMatcher().match([1, 0], in: directory)?.name == "Eric")
    }

    @Test("returns nil when nothing clears the threshold (a new speaker)")
    func noMatchBelowThreshold() {
        let directory = [enrolled("Eric", [1, 0])]
        #expect(VoiceprintMatcher().match([0, 1], in: directory) == nil)
    }

    @Test("an empty directory never matches")
    func emptyDirectory() {
        #expect(VoiceprintMatcher().match([1, 0], in: []) == nil)
    }

    @Test("a lower threshold admits a weaker match")
    func tunableThreshold() {
        let directory = [enrolled("Eric", [1, 1])]
        let query: [Float] = [1, 0] // cosine ≈ 0.707
        #expect(VoiceprintMatcher(threshold: 0.8).match(query, in: directory) == nil)
        #expect(VoiceprintMatcher(threshold: 0.6).match(query, in: directory)?.name == "Eric")
    }

    @Test("ties keep the earlier entry")
    func tiesKeepFirst() {
        let directory = [
            enrolled("First", [1, 0]),
            enrolled("Second", [1, 0]),
        ]
        #expect(VoiceprintMatcher().match([1, 0], in: directory)?.name == "First")
    }

    // MARK: nearest (threshold-free, for diagnostics)

    @Test("nearest returns the closest person even below the threshold")
    func nearestIgnoresThreshold() {
        let directory = [enrolled("Eric", [1, 0])]
        let query: [Float] = [0, 1] // cosine 0 — far below any threshold
        // bestMatch gates on the threshold and finds nothing…
        #expect(VoiceprintMatcher().bestMatch(query, in: directory) == nil)
        // …but nearest still reports who was closest, and how close.
        let nearest = VoiceprintMatcher().nearest(query, in: directory)
        #expect(nearest?.person.name == "Eric")
        #expect(nearest?.score == 0)
    }

    @Test("nearest returns nil only for an empty directory")
    func nearestEmptyDirectory() {
        #expect(VoiceprintMatcher().nearest([1, 0], in: []) == nil)
    }
}
