/// One on-disk AAC segment of a track's audio.
///
/// Continuous recording rotates through fixed-length segments so a crash loses
/// at most the in-flight segment, not the whole session. A segment's identity
/// is its ``source`` plus a monotonic ``index``; on disk it is a file named
/// like `microphone.0003.m4a` inside the session directory. See DESIGN.md §4.
public struct RecordingSegment: Sendable, Equatable {
    /// Which track this segment belongs to.
    public let source: CaptureSource

    /// Zero-based position of this segment within its track.
    public let index: Int

    public init(source: CaptureSource, index: Int) {
        self.source = source
        self.index = index
    }

    /// File name within the session directory, e.g. `microphone.0003.m4a`.
    public var fileName: String {
        "\(source.rawValue).\(Self.pad(index)).m4a"
    }

    /// Parses a segment from a file name, or `nil` if it doesn't match the
    /// scheme `<source>.<index>.m4a`.
    public init?(fileName: String) {
        let parts = fileName.split(separator: ".")
        guard parts.count == 3,
              parts[2] == "m4a",
              let source = CaptureSource(rawValue: String(parts[0])),
              let index = Int(parts[1]),
              index >= 0
        else { return nil }
        self.source = source
        self.index = index
    }

    /// Left-pads `index` to at least four digits (wider for long sessions).
    private static func pad(_ index: Int) -> String {
        let digits = String(index)
        let width = 4
        guard digits.count < width else { return digits }
        return String(repeating: "0", count: width - digits.count) + digits
    }
}

/// Plans segment rotation for continuous recording. A fixed wall-clock segment
/// length bounds how much audio a crash can lose. See DESIGN.md §4, §10.
public struct SegmentRotationPolicy: Sendable, Equatable {
    /// Length of each segment. Default 60 s.
    public let segmentLength: Duration

    public init(segmentLength: Duration = .seconds(60)) {
        self.segmentLength = segmentLength
    }

    /// The segment index a given elapsed offset falls into. Negative offsets
    /// clamp to the first segment.
    public func segmentIndex(at elapsed: Duration) -> Int {
        let length = segmentLength.components.seconds
        guard length > 0 else { return 0 }
        let offset = max(0, elapsed.components.seconds)
        return Int(offset / length)
    }

    /// Whether `elapsed` has crossed into a new segment past `currentIndex`.
    public func shouldRotate(at elapsed: Duration, currentIndex: Int) -> Bool {
        segmentIndex(at: elapsed) > currentIndex
    }
}

/// Reconstructs what's recoverable from a session directory after a crash.
///
/// Continuous recording leaves one or more numbered segments per track on disk.
/// A clean stop writes a finalize marker; its absence means the session was
/// interrupted and its segments should be recovered and finalized on next
/// launch. All functions here are pure over a directory's file names, so
/// recovery logic is testable without touching the filesystem. See DESIGN.md
/// §10.
public enum SessionRecovery {
    /// Name of the marker file written when a session finalizes cleanly.
    public static let finalizedMarker = "FINALIZED"

    /// Groups recoverable segments by source, each ordered by index, from the
    /// raw file names in a session directory. Unrecognized names are ignored.
    public static func segments(
        from fileNames: [String]
    ) -> [CaptureSource: [RecordingSegment]] {
        var grouped: [CaptureSource: [RecordingSegment]] = [:]
        for name in fileNames {
            guard let segment = RecordingSegment(fileName: name) else { continue }
            grouped[segment.source, default: []].append(segment)
        }
        return grouped.mapValues { $0.sorted { $0.index < $1.index } }
    }

    /// Whether the session finalized cleanly (marker present).
    public static func isFinalized(fileNames: [String]) -> Bool {
        fileNames.contains(finalizedMarker)
    }

    /// Whether the session needs recovery: it has at least one segment but no
    /// finalize marker.
    public static func needsRecovery(fileNames: [String]) -> Bool {
        !isFinalized(fileNames: fileNames) && !segments(from: fileNames).isEmpty
    }
}
