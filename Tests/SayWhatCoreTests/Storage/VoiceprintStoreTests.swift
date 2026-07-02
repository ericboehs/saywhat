import Foundation
import GRDB
import Testing
@testable import SayWhatCore

@Suite("VoiceprintStore")
struct VoiceprintStoreTests {
    /// Enroll a person with one or more exemplar embeddings, returning the person.
    @discardableResult
    private func enroll(
        _ store: VoiceprintStore,
        _ name: String,
        _ embeddings: [Float]...
    ) throws -> Person {
        let person = Person(name: name)
        try store.savePerson(person)
        for embedding in embeddings {
            try store.save(Voiceprint(personID: person.id, embedding: embedding))
        }
        return person
    }

    // MARK: persistence

    @Test("an enrolled person comes back with their exemplar intact")
    func roundTrip() throws {
        let store = try VoiceprintStore()
        let eric = try enroll(store, "Eric", [0.1, 0.2, 0.3])

        let enrolled = try store.enrolledPersons()
        #expect(enrolled.map(\.person) == [eric])
        #expect(enrolled.first?.exemplars.map(\.embedding) == [[0.1, 0.2, 0.3]])
        #expect(enrolled.first?.exemplars.first?.personID == eric.id)
    }

    @Test("a person owns a set of exemplars")
    func multipleExemplars() throws {
        let store = try VoiceprintStore()
        try enroll(store, "Eric", [1, 0], [0, 1], [1, 1])

        let enrolled = try store.enrolledPersons()
        #expect(enrolled.count == 1)
        #expect(enrolled.first?.exemplars.count == 3)
    }

    @Test("savePerson replaces the row with the same id, renaming the person")
    func personUpsert() throws {
        let store = try VoiceprintStore()
        let eric = try enroll(store, "Eric", [1, 0])
        try store.savePerson(Person(id: eric.id, name: "Eric Boehs"))

        let enrolled = try store.enrolledPersons()
        #expect(enrolled.count == 1)
        #expect(enrolled.first?.person.name == "Eric Boehs")
        #expect(enrolled.first?.exemplars.count == 1)
    }

    @Test("person(named:) finds an enrolled name and nil for an unknown one")
    func personLookup() throws {
        let store = try VoiceprintStore()
        let eric = try enroll(store, "Eric", [1, 0])

        #expect(try store.person(named: "Eric") == eric)
        #expect(try store.person(named: "Nobody") == nil)
    }

    @Test("an un-owned exemplar is not an enrolled person")
    func unownedExemplarsExcluded() throws {
        let store = try VoiceprintStore()
        try store.save(Voiceprint(embedding: [1, 0])) // personID nil — a stray mint

        #expect(try store.enrolledPersons().isEmpty)
    }

    @Test("delete removes one exemplar; deleting an absent id is a no-op")
    func delete() throws {
        let store = try VoiceprintStore()
        let person = Person(name: "Eric")
        try store.savePerson(person)
        let keep = Voiceprint(personID: person.id, embedding: [1, 0])
        let drop = Voiceprint(personID: person.id, embedding: [0, 1])
        try store.save(keep)
        try store.save(drop)

        try store.delete(id: UUID()) // absent — must not throw or remove anything
        #expect(try store.enrolledPersons().first?.exemplars.count == 2)

        try store.delete(id: drop.id)
        #expect(try store.enrolledPersons().first?.exemplars.map(\.id) == [keep.id])
    }

    @Test("the directory is ordered by name")
    func orderedByName() throws {
        let store = try VoiceprintStore()
        try enroll(store, "Charlie", [1])
        try enroll(store, "Alice", [1])
        try enroll(store, "Bob", [1])

        #expect(try store.enrolledPersons().map(\.person.name) == ["Alice", "Bob", "Charlie"])
    }

    @Test("a file-backed store persists across reopen")
    func persistsToDisk() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceprints-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let eric = try enroll(VoiceprintStore(path: path), "Eric", [0.4, 0.5, 0.6])

        let reopened = try VoiceprintStore(path: path)
        let enrolled = try reopened.enrolledPersons()
        #expect(enrolled.map(\.person) == [eric])
        #expect(enrolled.first?.exemplars.map(\.embedding) == [[0.4, 0.5, 0.6]])
    }

    @Test("an exemplar whose id isn't a valid UUID is skipped, not fatal")
    func skipsCorruptRow() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceprints-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = try VoiceprintStore(path: path)
        let eric = try enroll(store, "Eric", [1, 0])

        // Inject a corrupt exemplar id directly through a second connection.
        let raw = try DatabaseQueue(path: path)
        try raw.write { db in
            try db.execute(
                sql: "INSERT INTO voiceprint (id, person_id, embedding) VALUES (?, ?, ?)",
                arguments: ["not-a-uuid", eric.id.uuidString, VoiceprintStore.encode([0, 1])]
            )
        }

        #expect(try store.enrolledPersons().first?.exemplars.map(\.embedding) == [[1, 0]])
    }

    @Test("a person's attendee-email link persists and can be added later")
    func personEmail() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceprints-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = try VoiceprintStore(path: path)
        var alex = Person(name: "Alex", email: "alex@example.com")
        try store.savePerson(alex)
        try store.save(Voiceprint(personID: alex.id, embedding: [1, 0]))

        #expect(try VoiceprintStore(path: path).person(named: "Alex")?.email == "alex@example.com")

        // Naming from a later invite adds the link to an existing person.
        alex.email = "alex.teal@example.com"
        try store.savePerson(alex)
        #expect(try store.enrolledPersons().first?.person.email == "alex.teal@example.com")
    }

    // MARK: legacy migration

    @Test(
        "the legacy name-per-row schema migrates to persons, grouping by name and dropping Speaker N"
    )
    func migratesLegacySchema() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceprints-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Build the original schema by hand, recording only the first migration as
        // applied so the store runs the rest (count + persons) over real legacy data.
        let raw = try DatabaseQueue(path: path)
        try raw.write { db in
            try db.execute(sql: """
            CREATE TABLE voiceprint (id TEXT PRIMARY KEY, name TEXT NOT NULL, embedding BLOB NOT NULL)
            """)
            try db
                .execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            try db
                .execute(
                    sql: "INSERT INTO grdb_migrations (identifier) VALUES ('createVoiceprint')"
                )
            for (name, embedding) in [
                ("Zwag", [Float(1), 0]),
                ("Zwag", [Float(0), 1]),
                ("Theo", [Float(1), 1]),
                ("Speaker 5", [Float(-1), 0]),
            ] {
                try db.execute(
                    sql: "INSERT INTO voiceprint (id, name, embedding) VALUES (?, ?, ?)",
                    arguments: [UUID().uuidString, name, VoiceprintStore.encode(embedding)]
                )
            }
        }

        let store = try VoiceprintStore(path: path)
        let enrolled = try store.enrolledPersons()

        // Two distinct people; the three "Zwag" rows collapse to one person with
        // two exemplars; the generic "Speaker 5" mint is gone.
        #expect(enrolled.map(\.person.name) == ["Theo", "Zwag"])
        #expect(enrolled.first(where: { $0.person.name == "Zwag" })?.exemplars.count == 2)
        #expect(enrolled.first(where: { $0.person.name == "Theo" })?.exemplars.count == 1)
    }

    // MARK: merge

    @Test("merging folds one person's exemplars into another and drops the source")
    func mergeFoldsExemplars() throws {
        let store = try VoiceprintStore()
        let keep = try enroll(store, "Zwag", [1, 0])
        let dupe = try enroll(store, "Zwag", [0, 1], [1, 1])

        try store.merge(dupe.id, into: keep.id)

        let enrolled = try store.enrolledPersons()
        #expect(enrolled.map(\.person) == [keep])
        #expect(enrolled.first?.exemplars.count == 3)
    }

    @Test("merging a person into itself is a no-op")
    func mergeSelfNoOp() throws {
        let store = try VoiceprintStore()
        let eric = try enroll(store, "Eric", [1, 0])

        try store.merge(eric.id, into: eric.id)

        let enrolled = try store.enrolledPersons()
        #expect(enrolled.map(\.person) == [eric])
        #expect(enrolled.first?.exemplars.count == 1)
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
