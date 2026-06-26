import Foundation

/// One diarized span as the offline engine reports it: an opaque speaker
/// identifier plus a time range. A thin, FluidAudio-free mirror of the engine's
/// segment so the slot-assignment logic below can be unit-tested without loading
/// any model.
public struct RawSpeakerSegment: Sendable, Equatable {
    /// The engine's opaque speaker id (e.g. a cluster label like `"speaker_2"`).
    public let speakerId: String
    public let range: Range<Duration>

    public init(speakerId: String, range: Range<Duration>) {
        self.speakerId = speakerId
        self.range = range
    }
}

/// Projects an offline diarizer's segments onto our ``SpeakerTimeline`` — the
/// pure seam behind ``OfflinePyannoteDiarizer``.
///
/// The offline engine labels turns with opaque string ids; the rest of the app
/// speaks in small integer slots (`SpeakerTurn.speaker`, which the merge step
/// turns into `Speaker 1`, `Speaker 2`, …). This assigns each distinct id a
/// 0-based slot in **first-talk order** — so `Speaker 1` is whoever spoke first
/// — and drops empty spans. Deterministic, no I/O; the model lives
/// in the adapter, its output is tested here. DESIGN.md §6 (the same
/// TranscriptMerger / ParakeetSegmentBuilder pattern).
public struct OfflineTimelineBuilder: Sendable {
    public init() {}

    /// Build a ``SpeakerTimeline`` from raw diarized segments, assigning integer
    /// speaker slots by the order each id first speaks.
    public func timeline(from segments: [RawSpeakerSegment]) -> SpeakerTimeline {
        let ordered = segments
            .filter { $0.range.upperBound > $0.range.lowerBound }
            .sorted { $0.range.lowerBound < $1.range.lowerBound }

        var slots: [String: Int] = [:]
        var turns: [SpeakerTurn] = []
        for segment in ordered {
            let slot = slots[segment.speakerId] ?? {
                let next = slots.count
                slots[segment.speakerId] = next
                return next
            }()
            turns.append(SpeakerTurn(speaker: slot, range: segment.range))
        }
        return SpeakerTimeline(turns: turns)
    }
}
