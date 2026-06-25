import Testing
@testable import SayWhatCore

@Suite("SayWhat core")
struct SayWhatTests {
    @Test("version is non-empty")
    func versionIsSet() {
        #expect(!SayWhat.version.isEmpty)
    }

    @Test("timecode formats durations under an hour as M:SS", arguments: [
        (0, "0:00"),
        (5, "0:05"),
        (65, "1:05"),
        (600, "10:00"),
        (3599, "59:59"),
    ])
    func timecodeUnderHour(seconds: Int, expected: String) {
        #expect(SayWhat.timecode(seconds: seconds) == expected)
    }

    @Test("timecode formats an hour or more as H:MM:SS")
    func timecodeWithHours() {
        #expect(SayWhat.timecode(seconds: 3600) == "1:00:00")
        #expect(SayWhat.timecode(seconds: 3661) == "1:01:01")
    }

    @Test("timecode clamps negative input to zero")
    func timecodeClampsNegative() {
        #expect(SayWhat.timecode(seconds: -5) == "0:00")
    }
}
