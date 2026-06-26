import Foundation
import Testing
@testable import SayWhatCore

@Suite("VoiceprintMatcher")
struct VoiceprintMatcherTests {
    private func voiceprint(_ name: String, _ embedding: [Float]) -> Voiceprint {
        Voiceprint(name: name, embedding: embedding)
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

    @Test("returns the closest enrolled voiceprint above threshold")
    func matchesClosest() {
        let directory = [
            voiceprint("Eric", [1, 0, 0]),
            voiceprint("Ashley", [0, 1, 0]),
        ]
        #expect(VoiceprintMatcher().match([0.9, 0.1, 0], in: directory)?.name == "Eric")
        #expect(VoiceprintMatcher().match([0.1, 0.95, 0], in: directory)?.name == "Ashley")
    }

    @Test("returns nil when nothing clears the threshold (a new speaker)")
    func noMatchBelowThreshold() {
        let directory = [voiceprint("Eric", [1, 0])]
        #expect(VoiceprintMatcher().match([0, 1], in: directory) == nil)
    }

    @Test("an empty directory never matches")
    func emptyDirectory() {
        #expect(VoiceprintMatcher().match([1, 0], in: []) == nil)
    }

    @Test("a lower threshold admits a weaker match")
    func tunableThreshold() {
        let directory = [voiceprint("Eric", [1, 1])]
        let query: [Float] = [1, 0] // cosine ≈ 0.707
        #expect(VoiceprintMatcher(threshold: 0.8).match(query, in: directory) == nil)
        #expect(VoiceprintMatcher(threshold: 0.6).match(query, in: directory)?.name == "Eric")
    }

    @Test("ties keep the earlier entry")
    func tiesKeepFirst() {
        let directory = [
            voiceprint("First", [1, 0]),
            voiceprint("Second", [1, 0]),
        ]
        #expect(VoiceprintMatcher().match([1, 0], in: directory)?.name == "First")
    }
}
