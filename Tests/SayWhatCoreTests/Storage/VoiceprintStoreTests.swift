import Foundation
import GRDB
import Testing
@testable import SayWhatCore

@Suite("VoiceprintStore")
struct VoiceprintStoreTests {
    private func voiceprint(_ name: String, _ embedding: [Float]) -> Voiceprint {
        Voiceprint(name: name, embedding: embedding)
    }

    // MARK: persistence

    @Test("saved voiceprints come back intact")
    func roundTrip() throws {
        let store = try VoiceprintStore()
        let eric = voiceprint("Eric", [0.1, 0.2, 0.3])
        try store.save(eric)

        let all = try store.all()
        #expect(all == [eric])
    }

    @Test("save replaces the row with the same id")
    func upsert() throws {
        let store = try VoiceprintStore()
        let original = voiceprint("Eric", [1, 0])
        try store.save(original)
        try store.save(Voiceprint(id: original.id, name: "Eric Boehs", embedding: [0, 1]))

        let all = try store.all()
        #expect(all.count == 1)
        #expect(all.first?.name == "Eric Boehs")
        #expect(all.first?.embedding == [0, 1])
    }

    @Test("delete removes a voiceprint; deleting an absent id is a no-op")
    func delete() throws {
        let store = try VoiceprintStore()
        let eric = voiceprint("Eric", [1, 0])
        try store.save(eric)

        try store.delete(id: UUID()) // absent — must not throw or remove anything
        #expect(try store.all() == [eric])

        try store.delete(id: eric.id)
        #expect(try store.all().isEmpty)
    }

    @Test("the directory is ordered by name")
    func orderedByName() throws {
        let store = try VoiceprintStore()
        try store.save(voiceprint("Charlie", [1]))
        try store.save(voiceprint("Alice", [1]))
        try store.save(voiceprint("Bob", [1]))

        #expect(try store.all().map(\.name) == ["Alice", "Bob", "Charlie"])
    }

    @Test("a file-backed store persists across reopen")
    func persistsToDisk() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceprints-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let eric = voiceprint("Eric", [0.4, 0.5, 0.6])
        try VoiceprintStore(path: path).save(eric)

        let reopened = try VoiceprintStore(path: path)
        #expect(try reopened.all() == [eric])
    }

    @Test("a row whose id isn't a valid UUID is skipped, not fatal")
    func skipsCorruptRow() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceprints-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = try VoiceprintStore(path: path)
        let eric = voiceprint("Eric", [1, 0])
        try store.save(eric)

        // Inject a corrupt id directly through a second connection.
        let raw = try DatabaseQueue(path: path)
        try raw.write { db in
            try db.execute(
                sql: "INSERT INTO voiceprint (id, name, embedding) VALUES (?, ?, ?)",
                arguments: ["not-a-uuid", "Ghost", VoiceprintStore.encode([0, 1])]
            )
        }

        #expect(try store.all() == [eric])
    }

    // MARK: embedding codec

    @Test("encode/decode is a round trip")
    func codecRoundTrip() {
        let embedding: [Float] = [-1.5, 0, 0.25, 1024]
        #expect(VoiceprintStore.decode(VoiceprintStore.encode(embedding)) == embedding)
    }

    @Test("empty data decodes to an empty vector")
    func codecEmpty() {
        #expect(VoiceprintStore.decode(Data()) == [])
    }

    @Test("a trailing partial float is dropped")
    func codecTruncatesPartial() {
        var data = VoiceprintStore.encode([1, 2])
        data.append(0x7F) // one stray byte — not a whole Float
        #expect(VoiceprintStore.decode(data) == [1, 2])
    }
}
