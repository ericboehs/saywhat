import Testing
@testable import SayWhatCore

@Suite("Recording segment naming")
struct RecordingSegmentTests {
    @Test("file name zero-pads the index to four digits")
    func fileNameFormat() {
        #expect(RecordingSegment(source: .microphone, index: 3).fileName == "microphone.0003.m4a")
        #expect(RecordingSegment(source: .system, index: 0).fileName == "system.0000.m4a")
    }

    @Test("long sessions widen past four digits without truncating")
    func fileNameWideIndex() {
        #expect(RecordingSegment(source: .system, index: 12345).fileName == "system.12345.m4a")
    }

    @Test("parses a well-formed file name back to a segment")
    func parseRoundTrip() {
        let segment = RecordingSegment(source: .microphone, index: 7)
        let parsed = RecordingSegment(fileName: segment.fileName)
        #expect(parsed == segment)
    }

    @Test("round-trips across a range of indices")
    func roundTripRange() {
        for index in [0, 1, 42, 9999, 10000, 99999] {
            let segment = RecordingSegment(source: .system, index: index)
            #expect(RecordingSegment(fileName: segment.fileName) == segment)
        }
    }

    @Test("rejects malformed file names", arguments: [
        "microphone.m4a", // no index
        "microphone.0003.wav", // wrong extension
        "microphone.abc.m4a", // non-numeric index
        "speaker.0001.m4a", // unknown source
        "microphone.-1.m4a", // negative index
        "FINALIZED", // marker, not a segment
        "microphone.0001.0002.m4a", // too many components
    ])
    func rejectsMalformed(name: String) {
        #expect(RecordingSegment(fileName: name) == nil)
    }
}
