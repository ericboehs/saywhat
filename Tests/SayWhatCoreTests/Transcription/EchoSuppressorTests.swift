import Foundation
import Testing
@testable import SayWhatCore

@Suite("EchoSuppressor")
struct EchoSuppressorTests {
    /// A finalized segment on one track over `start..<end` seconds.
    private func segment(
        _ source: CaptureSource,
        _ text: String,
        from start: Double,
        to end: Double,
        isFinal: Bool = true
    ) -> TranscriptSegment {
        TranscriptSegment(
            source: source,
            text: text,
            range: .seconds(start) ..< .seconds(end),
            isFinal: isFinal
        )
    }

    @Test("a mic line repeating an overlapping remote line is an echo")
    func detectsEcho() {
        let suppressor = EchoSuppressor(system: [
            segment(.system, "what is rage blade built of", from: 0, to: 5),
        ])
        // The mic heard the echo slightly differently ("made" vs "built").
        #expect(suppressor.isEcho(
            text: "what is rage blade made of",
            range: .seconds(0) ..< .seconds(5)
        ))
    }

    @Test("a short mic reply is never suppressed, even if it matches")
    func keepsShortReply() {
        let suppressor = EchoSuppressor(system: [
            segment(.system, "yeah okay sure thing", from: 0, to: 1),
        ])
        #expect(!suppressor.isEcho(text: "yeah okay", range: .seconds(0) ..< .seconds(1)))
    }

    @Test("matching words far apart in time are not an echo")
    func ignoresDistantMatch() {
        let suppressor = EchoSuppressor(system: [
            segment(.system, "what is rage blade made of", from: 0, to: 5),
        ])
        #expect(!suppressor.isEcho(
            text: "what is rage blade made of",
            range: .seconds(100) ..< .seconds(105)
        ))
    }

    @Test("a genuine interjection over remote speech is kept")
    func keepsInterjection() {
        let suppressor = EchoSuppressor(system: [
            segment(.system, "the farm is actually decent", from: 0, to: 3),
        ])
        #expect(!suppressor.isEcho(
            text: "i totally disagree with everything",
            range: .seconds(0) ..< .seconds(3)
        ))
    }

    @Test("an empty directory of remote speech suppresses nothing")
    func emptySystemSuppressesNothing() {
        let suppressor = EchoSuppressor(system: [])
        #expect(!suppressor.isEcho(
            text: "what is rage blade made of",
            range: .seconds(0) ..< .seconds(5)
        ))
    }

    @Test("non-final and punctuation-only remote segments are ignored")
    func ignoresVolatileAndPunctuation() {
        let suppressor = EchoSuppressor(system: [
            segment(.system, "what is rage blade made of", from: 0, to: 5, isFinal: false),
            segment(.system, ".", from: 0, to: 5),
        ])
        #expect(!suppressor.isEcho(
            text: "what is rage blade made of",
            range: .seconds(0) ..< .seconds(5)
        ))
    }
}
