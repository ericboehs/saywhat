import Foundation
import Testing
@testable import SayWhatCore

@Suite("TranscriptSegment")
struct TranscriptSegmentTests {
    private func segment(
        _ text: String,
        from: Duration = .seconds(1),
        to: Duration = .seconds(2),
        source: CaptureSource = .microphone,
        isFinal: Bool = true
    ) -> TranscriptSegment {
        TranscriptSegment(source: source, text: text, range: from ..< to, isFinal: isFinal)
    }

    @Test("exposes start and end from its range")
    func startEnd() {
        let seg = segment("hello", from: .seconds(3), to: .seconds(5))
        #expect(seg.start == .seconds(3))
        #expect(seg.end == .seconds(5))
    }

    @Test("isVolatile is the inverse of isFinal")
    func volatility() {
        #expect(segment("draft", isFinal: false).isVolatile)
        #expect(!segment("committed", isFinal: true).isVolatile)
    }

    @Test("allows an empty range for a just-started volatile guess")
    func emptyRange() {
        let seg = segment("um", from: .seconds(4), to: .seconds(4), isFinal: false)
        #expect(seg.range.isEmpty)
        #expect(seg.start == seg.end)
    }

    @Test("equality distinguishes track, text, range, and finality")
    func equality() {
        let base = segment("hi")
        #expect(base == segment("hi"))
        #expect(base != segment("bye"))
        #expect(base != segment("hi", source: .system))
        #expect(base != segment("hi", to: .seconds(3)))
        #expect(base != segment("hi", isFinal: false))
    }
}
