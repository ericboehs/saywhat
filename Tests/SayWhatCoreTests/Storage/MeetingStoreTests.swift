import Foundation
import Testing
@testable import SayWhatCore

@Suite("Meeting store")
struct MeetingStoreTests {
    /// A throwaway session directory, cleaned up when the test ends.
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("a saved meeting round-trips, roster included")
    func roundTrip() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let meeting = MeetingEvent(
            title: "EERT sync",
            start: Date(timeIntervalSince1970: 1_000_000),
            end: Date(timeIntervalSince1970: 1_003_600),
            attendees: [
                MeetingAttendee(name: "Alex Teal", email: "alex@example.com"),
                MeetingAttendee(name: "Eric Boehs", isCurrentUser: true),
            ]
        )

        try MeetingStore(directory: directory).save(meeting)

        #expect(MeetingStore(directory: directory).load() == meeting)
    }

    @Test("no saved document loads as nil")
    func missingIsNil() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(MeetingStore(directory: directory).load() == nil)
    }

    @Test("a corrupt document degrades to nil, never an error")
    func corruptIsNil() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(MeetingStore.defaultFileName)
        try Data("not json".utf8).write(to: file)
        #expect(MeetingStore(directory: directory).load() == nil)
    }
}
