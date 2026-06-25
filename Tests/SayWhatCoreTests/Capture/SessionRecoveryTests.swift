import Testing
@testable import SayWhatCore

@Suite("Session crash recovery")
struct SessionRecoveryTests {
    @Test("groups segments by source, ordered by index, ignoring junk")
    func groupsAndOrders() {
        let files = [
            "system.0002.m4a",
            "microphone.0000.m4a",
            "system.0000.m4a",
            "microphone.0001.m4a",
            ".DS_Store", // junk, ignored
            "notes.txt", // junk, ignored
        ]
        let grouped = SessionRecovery.segments(from: files)

        #expect(grouped[.microphone]?.map(\.index) == [0, 1])
        #expect(grouped[.system]?.map(\.index) == [0, 2])
    }

    @Test("a finalize marker means no recovery is needed")
    func finalizedSession() {
        let files = ["microphone.0000.m4a", "system.0000.m4a", SessionRecovery.finalizedMarker]
        #expect(SessionRecovery.isFinalized(fileNames: files))
        #expect(!SessionRecovery.needsRecovery(fileNames: files))
    }

    @Test("segments without a marker need recovery")
    func interruptedSession() {
        let files = ["microphone.0000.m4a", "microphone.0001.m4a"]
        #expect(!SessionRecovery.isFinalized(fileNames: files))
        #expect(SessionRecovery.needsRecovery(fileNames: files))
    }

    @Test("an empty or junk-only directory needs no recovery")
    func nothingToRecover() {
        #expect(!SessionRecovery.needsRecovery(fileNames: []))
        #expect(!SessionRecovery.needsRecovery(fileNames: [".DS_Store"]))
    }
}
