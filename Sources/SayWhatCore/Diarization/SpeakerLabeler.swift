import Foundation

/// Who a transcript segment is attributed to in the live view.
public enum SpeakerLabel: Sendable, Equatable, Hashable {
    /// The local user (the mic channel).
    case you
    /// A remote speaker, by the diarizer's slot/cluster index.
    case remote(Int)
}

/// A track's per-frame energy envelope, accumulated as frames arrive so a
/// transcript segment's dominant source can be decided after the fact by
/// comparing the two tracks over the segment's window.
public struct EnergyTrack: Sendable, Equatable {
    private struct Span: Equatable {
        let range: Range<Duration>
        let rms: Float
    }

    private var spans: [Span] = []

    public init() {}

    /// Record one captured frame's energy at its place on the session timeline.
    public mutating func record(_ frame: AudioFrame) {
        let end = frame.startOffset + frame.duration
        guard end > frame.startOffset else { return }
        spans.append(Span(range: frame.startOffset ..< end, rms: frame.rms))
    }

    /// Overlap-weighted energy over `range`: each frame's RMS scaled by how much
    /// of it falls inside the window. Comparable across tracks for the same
    /// window to decide which one dominated.
    public func energy(in range: Range<Duration>) -> Double {
        var total = 0.0
        for span in spans {
            let overlap = range.overlap(with: span.range)
            if overlap > 0 { total += Double(span.rms) * overlap }
        }
        return total
    }
}

/// Attributes a transcript segment to a ``SpeakerLabel`` by combining the free
/// channel signal (mic = you) with the system-track diarizer (remote speakers).
///
/// The mic dominates its own window when you speak; when a remote speaker holds
/// the floor the mic carries only attenuated echo, so the system track wins. A
/// bias toward "remote" keeps that leaked echo from being mistaken for you.
public struct SpeakerLabeler: Sendable {
    /// How many times louder the mic must be than the system track over a
    /// segment's window to call it the local speaker. `1.0` is a simple
    /// majority; `> 1` biases toward "remote" to absorb mic echo of remote audio.
    public var youThreshold: Double

    public init(youThreshold: Double = 1.5) {
        self.youThreshold = youThreshold
    }

    /// Label `segment` given both tracks' energy and the remote-speaker timeline.
    /// Falls back to remote slot `0` when no diarized turn covers the window.
    public func label(
        segment: Range<Duration>,
        mic: EnergyTrack,
        system: EnergyTrack,
        remoteSpeakers: SpeakerTimeline
    ) -> SpeakerLabel {
        let micEnergy = mic.energy(in: segment)
        let systemEnergy = system.energy(in: segment)
        if micEnergy >= systemEnergy * youThreshold {
            return .you
        }
        return .remote(remoteSpeakers.dominantSpeaker(in: segment) ?? 0)
    }
}
