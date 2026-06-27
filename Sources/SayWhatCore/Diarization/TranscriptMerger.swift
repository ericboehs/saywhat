import Foundation

/// Merges the final pass's two ASR tracks into one authoritative ``Transcript``.
///
/// The final pass transcribes each saved track separately (the separate-tracks
/// invariant holds through to the end): the **mic** track is always *you*, and
/// the **system** track holds the remote speakers, split by offline diarization
/// into a ``SpeakerTimeline``. This folds the two into a single timeline-ordered
/// record — each system utterance tagged with the remote speaker who dominated
/// its window — and coalesces consecutive same-speaker turns into one block, the
/// way a reader expects to see a conversation. DESIGN.md §3, §6.
///
/// Pure and deterministic: no models, no I/O. The ML adapters that produce its
/// inputs live behind ``Transcriber`` / ``Diarizer``; this is the unit-testable
/// seam where their outputs come together.
public struct TranscriptMerger: Sendable {
    public init() {}

    /// Combine final mic + system segments into the authoritative transcript.
    ///
    /// - Parameters:
    ///   - mic: finalized segments from the mic track (attributed to *you*).
    ///   - system: finalized segments from the system track (remote speakers).
    ///   - remoteSpeakers: offline diarization of the system track, used to name
    ///     each system segment's remote slot. Absent coverage falls back to slot 0.
    ///   - names: optional remote slot → persistent identity (e.g. `1: "Eric"`)
    ///     from ``SpeakerResolver``. A slot with no entry keeps its generic label.
    /// Volatile or empty segments are ignored; the result is ordered by start time.
    public func merge(
        mic: [TranscriptSegment],
        system: [TranscriptSegment],
        remoteSpeakers: SpeakerTimeline,
        names: [Int: String] = [:]
    ) -> Transcript {
        var labeled: [LabeledSegment] = []
        for segment in mic where segment.isFinal {
            labeled.append(LabeledSegment(label: .you, name: nil, segment: segment))
        }
        for segment in system where segment.isFinal {
            let slot = remoteSpeakers.dominantSpeaker(in: segment.range) ?? 0
            labeled.append(LabeledSegment(
                label: .remote(slot),
                name: names[slot],
                segment: segment
            ))
        }
        labeled.sort { $0.segment.start < $1.segment.start }

        var utterances: [Transcript.Utterance] = []
        for entry in labeled {
            let label = entry.label
            let text = entry.segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = utterances.last, last.speaker == label {
                // Same speaker still holds the floor — extend their block.
                utterances[utterances.count - 1] = Transcript.Utterance(
                    id: last.id,
                    speaker: label,
                    speakerName: last.speakerName,
                    text: last.text + " " + text,
                    range: last.start ..< Swift.max(last.end, entry.segment.end)
                )
            } else {
                utterances.append(Transcript.Utterance(
                    id: utterances.count,
                    speaker: label,
                    speakerName: entry.name,
                    text: text,
                    range: entry.segment.range
                ))
            }
        }
        return Transcript(utterances: utterances)
    }

    /// A finalized segment paired with its resolved speaker label and identity —
    /// the intermediate the merge sorts and coalesces over.
    private struct LabeledSegment {
        let label: SpeakerLabel
        let name: String?
        let segment: TranscriptSegment
    }
}
