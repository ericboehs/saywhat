import Foundation
import GRDB

/// On-device SQLite store for enrolled speakers — the persistence behind
/// cross-session identity (DESIGN.md §6). Strictly local: nothing here ever leaves
/// the machine (the on-device invariant, CLAUDE.md).
///
/// Identity is modelled as a ``Person`` owning a set of ``Voiceprint`` exemplars
/// (docs/speaker-identity-exemplars.md): the `person` table holds the name, the
/// `voiceprint` table holds each take's embedding and points back via `person_id`.
/// An exemplar with a null `person_id` is an un-named mint and is never persisted
/// here — minting stays in memory until the user names it. The embedding is a raw
/// little-endian Float32 BLOB (compact; portability is moot, every target is Apple
/// Silicon). Matching policy stays in ``VoiceprintMatcher``.
public struct VoiceprintStore: Sendable {
    private let database: DatabaseQueue

    /// Open (creating if needed) the store at `path`.
    public init(path: String) throws {
        database = try DatabaseQueue(path: path)
        try Self.migrate(database)
    }

    /// An ephemeral in-memory store, for tests and previews.
    public init() throws {
        database = try DatabaseQueue()
        try Self.migrate(database)
    }

    private static func migrate(_ database: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createVoiceprint") { db in
            try db.create(table: "voiceprint") { table in
                table.primaryKey("id", .text)
                table.column("name", .text).notNull()
                table.column("embedding", .blob).notNull()
            }
        }
        // A prior build added this column; re-registered so databases that already
        // applied it stay consistent with the migrator. Vestigial under the
        // exemplar model (reinforcement counts return in a later phase).
        migrator.registerMigration("addVoiceprintCount") { db in
            try db.alter(table: "voiceprint") { table in
                table.add(column: "count", .integer).notNull().defaults(to: 1)
            }
        }
        // Move to the Person ⟶ exemplars model: a `person` table owns the name,
        // each voiceprint points back via `person_id`. Existing named rows are
        // grouped one person per distinct name (so three "Zwag" rows become one
        // Zwag with three exemplars); stale generic `Speaker N` mints are dropped
        // — they were never real identities, just per-session labels that leaked
        // into persistence and re-polluted matching.
        migrator.registerMigration("addPersonExemplars") { db in
            try db.create(table: "person") { table in
                table.primaryKey("id", .text)
                table.column("name", .text).notNull()
            }
            try db.alter(table: "voiceprint") { table in
                table.add(column: "person_id", .text)
            }
            var personIDByName: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, name FROM voiceprint") {
                let voiceprintID: String = row["id"]
                let name: String = row["name"]
                if isGenericSpeakerName(name) {
                    try db.execute(
                        sql: "DELETE FROM voiceprint WHERE id = ?",
                        arguments: [voiceprintID]
                    )
                    continue
                }
                let personID: String
                if let existing = personIDByName[name] {
                    personID = existing
                } else {
                    personID = UUID().uuidString
                    personIDByName[name] = personID
                    try db.execute(
                        sql: "INSERT INTO person (id, name) VALUES (?, ?)",
                        arguments: [personID, name]
                    )
                }
                try db.execute(
                    sql: "UPDATE voiceprint SET person_id = ? WHERE id = ?",
                    arguments: [personID, voiceprintID]
                )
            }
            try db.alter(table: "voiceprint") { table in
                table.drop(column: "name")
            }
        }
        try migrator.migrate(database)
    }

    // MARK: persons

    /// Every enrolled person with their exemplars, ordered by name for a stable
    /// directory. Persons with no exemplars are omitted (nothing to match against).
    public func enrolledPersons() throws -> [EnrolledPerson] {
        try database.read { db in
            let persons = try Row
                .fetchAll(db, sql: "SELECT id, name FROM person ORDER BY name")
                .compactMap(Self.person(from:))
            let exemplars = try Row
                .fetchAll(
                    db,
                    sql: "SELECT id, person_id, embedding FROM voiceprint WHERE person_id IS NOT NULL"
                )
                .compactMap(Self.voiceprint(from:))
            let byPerson = Dictionary(grouping: exemplars, by: \.personID)
            return persons.compactMap { person in
                guard let prints = byPerson[person.id], !prints.isEmpty else { return nil }
                return EnrolledPerson(person: person, exemplars: prints)
            }
        }
    }

    /// The person with this exact name, if one is enrolled — the lookup behind
    /// "rename to an existing name binds to that person instead of forking one".
    public func person(named name: String) throws -> Person? {
        try database.read { db in
            try Row
                .fetchOne(
                    db,
                    sql: "SELECT id, name FROM person WHERE name = ? LIMIT 1",
                    arguments: [name]
                )
                .flatMap(Self.person(from:))
        }
    }

    /// Insert `person`, replacing any existing row with the same id.
    public func savePerson(_ person: Person) throws {
        try database.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO person (id, name) VALUES (?, ?)",
                arguments: [person.id.uuidString, person.name]
            )
        }
    }

    /// Fold `source` into `destination`: reassign every one of `source`'s exemplars
    /// to `destination`, then delete the now-empty `source` row. This is how two
    /// people the user has confirmed are one voice (duplicate "Zwag" entries) become
    /// one. A no-op when the ids are equal. Exemplars keep their ids — only their
    /// owner changes — so the merge is a pure re-parenting, done in one transaction.
    public func merge(_ source: UUID, into destination: UUID) throws {
        guard source != destination else { return }
        try database.write { db in
            try db.execute(
                sql: "UPDATE voiceprint SET person_id = ? WHERE person_id = ?",
                arguments: [destination.uuidString, source.uuidString]
            )
            try db.execute(
                sql: "DELETE FROM person WHERE id = ?",
                arguments: [source.uuidString]
            )
        }
    }

    // MARK: exemplars

    /// Insert `voiceprint`, replacing any existing row with the same id. A null
    /// `personID` stores an un-owned exemplar; callers attach it to a person first.
    public func save(_ voiceprint: Voiceprint) throws {
        try database.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO voiceprint (id, person_id, embedding) VALUES (?, ?, ?)",
                arguments: [
                    voiceprint.id.uuidString,
                    voiceprint.personID?.uuidString,
                    Self.encode(voiceprint.embedding),
                ]
            )
        }
    }

    /// Remove the exemplar with `id` (a no-op if it isn't present).
    public func delete(id: UUID) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM voiceprint WHERE id = ?", arguments: [id.uuidString])
        }
    }

    // MARK: row <-> value

    /// Reconstruct a ``Person`` from a row, skipping any whose id isn't a valid
    /// UUID (a corrupt write should drop one entry, not fail the whole read).
    private static func person(from row: Row) -> Person? {
        let idText: String = row["id"]
        guard let id = UUID(uuidString: idText) else { return nil }
        return Person(id: id, name: row["name"])
    }

    /// Reconstruct a ``Voiceprint`` from a row, skipping any whose id isn't a valid
    /// UUID. A present-but-invalid `person_id` reads as an un-owned exemplar.
    private static func voiceprint(from row: Row) -> Voiceprint? {
        let idText: String = row["id"]
        guard let id = UUID(uuidString: idText) else { return nil }
        let personIDText: String? = row["person_id"]
        let personID = personIDText.flatMap(UUID.init(uuidString:))
        let embedding: Data = row["embedding"]
        return Voiceprint(id: id, personID: personID, embedding: decode(embedding))
    }

    /// Whether `name` is an auto-generated `Speaker N` label rather than a real name.
    private static func isGenericSpeakerName(_ name: String) -> Bool {
        let prefix = "Speaker "
        guard name.hasPrefix(prefix) else { return false }
        return Int(name.dropFirst(prefix.count)) != nil
    }

    /// Pack a Float32 vector into its raw little-endian bytes.
    static func encode(_ embedding: [Float]) -> Data {
        embedding.withUnsafeBytes { Data($0) }
    }

    /// Unpack a Float32 vector from raw bytes; a non-multiple length is truncated.
    static func decode(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.stride
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self).prefix(count))
        }
    }
}
