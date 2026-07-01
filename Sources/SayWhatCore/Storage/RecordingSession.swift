import Foundation

/// A session's on-disk directory — the filesystem seam around the pure
/// ``SessionRecovery`` logic.
///
/// Owns one directory holding both tracks' rotating AAC segments plus the
/// finalize marker. It is the only place that touches the filesystem for a
/// session: it vends a ``DurableAACWriter`` per track, lists the directory for
/// recovery decisions (delegating the actual rules to ``SessionRecovery``), and
/// writes the finalize marker on a clean stop. Keeping I/O here lets the
/// recovery rules stay pure and unit-tested without a filesystem.
public struct RecordingSession: Sendable {
    /// The session directory; segments and the finalize marker live inside it.
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Creates the session directory if it doesn't already exist.
    public func createDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    /// A durable AAC writer for one track, writing into this session directory.
    public func writer(
        for source: CaptureSource,
        format: AudioStreamFormat = .model,
        rotation: SegmentRotationPolicy = SegmentRotationPolicy(),
        realTime: Bool = true
    ) throws -> DurableAACWriter {
        try DurableAACWriter(
            directory: directory,
            source: source,
            format: format,
            rotation: rotation,
            realTime: realTime
        )
    }

    /// The names currently in the session directory (empty if unreadable).
    public func fileNames() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    /// Recoverable segments grouped by track, ordered by index.
    public func segments() -> [CaptureSource: [RecordingSegment]] {
        SessionRecovery.segments(from: fileNames())
    }

    /// Whether the session has segments but no finalize marker — i.e. it was
    /// interrupted and should be recovered on next launch.
    public func needsRecovery() -> Bool {
        SessionRecovery.needsRecovery(fileNames: fileNames())
    }

    /// Whether the finalize marker is present.
    public func isFinalized() -> Bool {
        SessionRecovery.isFinalized(fileNames: fileNames())
    }

    /// Writes the finalize marker, marking the session cleanly closed. Idempotent.
    public func markFinalized() throws {
        let marker = directory.appendingPathComponent(SessionRecovery.finalizedMarker)
        try Data().write(to: marker)
    }
}
