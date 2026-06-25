import Testing
@testable import SayWhatCore

@Suite("Capture mode & source")
struct CaptureModeTests {
    @Test("video call records both tracks, mic first")
    func videoCallSources() {
        #expect(CaptureMode.videoCall.sources == [.microphone, .system])
        #expect(CaptureMode.videoCall.capturesSystemAudio)
    }

    @Test("in-person records mic only")
    func inPersonSources() {
        #expect(CaptureMode.inPerson.sources == [.microphone])
        #expect(!CaptureMode.inPerson.capturesSystemAudio)
    }

    @Test("every mode includes the microphone")
    func everyModeHasMic() {
        for mode in CaptureMode.allCases {
            #expect(mode.sources.contains(.microphone))
        }
    }

    @Test("capture sources have stable raw values")
    func sourceRawValues() {
        #expect(CaptureSource.microphone.rawValue == "microphone")
        #expect(CaptureSource.system.rawValue == "system")
        #expect(CaptureSource(rawValue: "system") == .system)
    }
}
