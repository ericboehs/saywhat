import Testing
@testable import SayWhatCore

@Suite("Segment rotation policy")
struct SegmentRotationPolicyTests {
    let policy = SegmentRotationPolicy() // default 60 s

    @Test("elapsed maps to the right segment index", arguments: [
        (Duration.seconds(0), 0),
        (Duration.seconds(59), 0),
        (Duration.seconds(60), 1),
        (Duration.seconds(125), 2),
        (Duration.seconds(3600), 60),
    ])
    func indexAtElapsed(elapsed: Duration, expected: Int) {
        #expect(policy.segmentIndex(at: elapsed) == expected)
    }

    @Test("negative elapsed clamps to the first segment")
    func negativeClamps() {
        #expect(policy.segmentIndex(at: .seconds(-5)) == 0)
    }

    @Test("rotates only after crossing into a new segment")
    func rotationBoundary() {
        #expect(!policy.shouldRotate(at: .seconds(59), currentIndex: 0))
        #expect(policy.shouldRotate(at: .seconds(60), currentIndex: 0))
        #expect(!policy.shouldRotate(at: .seconds(60), currentIndex: 1))
    }

    @Test("honors a custom segment length")
    func customLength() {
        let tenSecond = SegmentRotationPolicy(segmentLength: .seconds(10))
        #expect(tenSecond.segmentIndex(at: .seconds(25)) == 2)
    }
}
