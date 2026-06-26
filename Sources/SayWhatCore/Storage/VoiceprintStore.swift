import Foundation
import GRDB

/// On-device SQLite store for enrolled speaker ``Voiceprint``s — the persistence
/// behind cross-session speaker identity (DESIGN.md §6). Strictly local: nothing
/// here ever leaves the machine (the on-device invariant, CLAUDE.md).
///
/// The store owns only the persistence concern; matching policy stays in
/// ``VoiceprintMatcher``. The embedding is written as a raw little-endian Float32
/// BLOB rather than JSON — compact, and portability isn't a concern since every
/// target is Apple Silicon.
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
        try migrator.migrate(database)
    }

    /// Every enrolled voiceprint, ordered by name for a stable directory.
    public func all() throws -> [Voiceprint] {
        try database.read { db in
            try Row
                .fetchAll(db, sql: "SELECT id, name, embedding FROM voiceprint ORDER BY name")
                .compactMap(Self.voiceprint(from:))
        }
    }

    /// Insert `voiceprint`, replacing any existing row with the same id.
    public func save(_ voiceprint: Voiceprint) throws {
        try database.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO voiceprint (id, name, embedding) VALUES (?, ?, ?)",
                arguments: [
                    voiceprint.id.uuidString,
                    voiceprint.name,
                    Self.encode(voiceprint.embedding),
                ]
            )
        }
    }

    /// Remove the voiceprint with `id` (a no-op if it isn't present).
    public func delete(id: UUID) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM voiceprint WHERE id = ?", arguments: [id.uuidString])
        }
    }

    // MARK: row <-> value

    /// Reconstruct a ``Voiceprint`` from a row, skipping any row whose id isn't a
    /// valid UUID (a corrupt write should drop one entry, not fail the whole read).
    private static func voiceprint(from row: Row) -> Voiceprint? {
        let idText: String = row["id"]
        guard let id = UUID(uuidString: idText) else { return nil }
        let name: String = row["name"]
        let embedding: Data = row["embedding"]
        return Voiceprint(id: id, name: name, embedding: decode(embedding))
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
