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
    /// A silence between consecutive same-speaker words long enough to end the
    /// current paragraph and start a new (separately timestamped) one.
    private let paragraphPause: Duration
    /// A shorter silence that still ends a paragraph *when the previous text closed
    /// a sentence* — a speaker's own question and answer ("…again? Sure, …") are
    /// separated by a breath well under ``paragraphPause``, and fusing them into one
    /// block both mis-times the turn and reads worse than the two beats it was.
    private let sentencePause: Duration
    /// Once a paragraph runs this long, it breaks at the next sentence boundary so
    /// an uninterrupted monologue doesn't render as one unreadable wall of text.
    private let maxParagraph: Duration

    /// - Parameters:
    ///   - paragraphPause: pause between words that starts a new paragraph
    ///     (default 1.5s — comfortably past a between-sentence breath).
    ///   - sentencePause: the shorter pause that breaks a paragraph only when the
    ///     prior text ends a sentence (default 0.75s — a beat, not a mid-clause
    ///     hesitation), so a question and its own answer don't fuse.
    ///   - maxParagraph: soft cap after which a paragraph breaks at the next
    ///     sentence end (default 20s).
    public init(
        paragraphPause: Duration = .seconds(1.5),
        sentencePause: Duration = .seconds(0.75),
        maxParagraph: Duration = .seconds(20)
    ) {
        self.paragraphPause = paragraphPause
        self.sentencePause = sentencePause
        self.maxParagraph = maxParagraph
    }

    /// Combine final mic + system segments into the authoritative transcript.
    ///
    /// - Parameters:
    ///   - mic: finalized segments from the mic track (attributed to *you*).
    ///   - system: finalized segments from the system track (remote speakers).
    ///   - remoteSpeakers: offline diarization of the system track, used to name
    ///     each system segment's remote slot. Absent coverage falls back to slot 0.
    ///   - names: optional remote slot → persistent identity (e.g. `1: "Eric"`)
    ///     from ``SpeakerResolver``. A slot with no entry keeps its generic label.
    /// Volatile, empty, or punctuation-only segments are ignored; the result is
    /// ordered by start time.
    public func merge(
        mic: [TranscriptSegment],
        system: [TranscriptSegment],
        remoteSpeakers: SpeakerTimeline,
        names: [Int: String] = [:]
    ) -> Transcript {
        // Build the atoms the merge orders and coalesces, asymmetrically by track.
        //
        // The mic is *you* — the interjector in this app's core use (you react to
        // remote speakers). Each mic segment stays one **whole** atom: it lands at
        // its start time and splits the remote run there, rather than shredding. If
        // both tracks were exploded to words, two genuinely overlapping turns (you
        // talking over a long remote stretch) would interleave word-by-word into an
        // unreadable salad.
        //
        // The system track is exploded **per word**, because each word carries its
        // own remote-speaker slot from diarization — a second remote speaker's quick
        // line inside one ASR segment must become its own turn. Consecutive same-
        // speaker words re-coalesce below, so a remote turn that *isn't* interrupted
        // still renders as one block; a whole mic atom landing mid-run splits it.
        var atoms: [Atom] = []
        for segment in mic where segment.isFinal {
            atoms.append(Atom(
                label: .you,
                name: nil,
                text: segment.text,
                range: segment.range,
                words: segment.words
            ))
        }
        for segment in system where segment.isFinal {
            atoms.append(contentsOf: Self.remoteAtoms(
                of: segment,
                speakers: remoteSpeakers,
                names: names
            ))
        }
        // Order by start time; tie-break on end time so two words that begin
        // together stay deterministic across runs.
        atoms.sort { lhs, rhs in
            lhs.range.lowerBound != rhs.range.lowerBound
                ? lhs.range.lowerBound < rhs.range.lowerBound
                : lhs.range.upperBound < rhs.range.upperBound
        }

        var utterances: [Transcript.Utterance] = []
        for atom in atoms {
            let text = Self.cleanLeading(atom.text)
            // Require real content: the batch ASR sometimes emits a lone "."
            // which would otherwise render as an empty, mislabeled speaker turn.
            guard text.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            let last = utterances.last
            let extend = last.map { $0.speaker == atom.label && !breaksParagraph(
                after: $0,
                before: atom
            ) } ?? false
            if extend, let last {
                // Same speaker still holds the floor — extend their block,
                // concatenating the word timings in spoken order.
                utterances[utterances.count - 1] = Transcript.Utterance(
                    id: last.id,
                    speaker: atom.label,
                    speakerName: last.speakerName,
                    text: last.text + " " + text,
                    range: last.start ..< Swift.max(last.end, atom.range.upperBound),
                    words: last.words + atom.words
                )
            } else {
                utterances.append(Transcript.Utterance(
                    id: utterances.count,
                    speaker: atom.label,
                    speakerName: atom.name,
                    text: text,
                    range: atom.range,
                    words: atom.words
                ))
            }
        }
        return Transcript(utterances: utterances)
    }

    /// Whether the next same-speaker `atom` should start a fresh paragraph rather
    /// than extend `last`: after a real pause, or — once the paragraph is already
    /// long — at a sentence boundary, so a monologue reads as timestamped
    /// paragraphs instead of one wall of text.
    private func breaksParagraph(after last: Transcript.Utterance, before atom: Atom) -> Bool {
        let gap = atom.range.lowerBound - last.end
        if gap > paragraphPause { return true }
        if gap > sentencePause, Self.endsSentence(last.text) { return true }
        if atom.range.upperBound - last.start > maxParagraph, Self.endsSentence(last.text) {
            return true
        }
        return false
    }

    /// Sentence/clause marks the recognizer sometimes strands at the *start* of a
    /// segment (e.g. a trailing "." from the previous utterance that floated onto
    /// the next one). Interior and trailing punctuation is meaningful and untouched.
    private static let strayLeading: Set<Character> = [".", ",", ";", ":", "!", "?"]

    /// Trim leading whitespace and any stray leading sentence punctuation so an
    /// utterance never opens on a stranded ". " or ", " the way the batch ASR
    /// occasionally emits, then trim trailing whitespace.
    private static func cleanLeading(_ text: String) -> String {
        String(text.drop { $0.isWhitespace || strayLeading.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether `text` ends a sentence — its last non-space character is `.`, `?`,
    /// or `!` — used to break a long paragraph only at a clean boundary.
    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.reversed().first(where: { !$0.isWhitespace }) else { return false }
        return last == "." || last == "?" || last == "!"
    }

    /// Split a *system* segment into per-word atoms, each tagged with the remote
    /// speaker who dominated **that word's** window — so a second speaker's short
    /// interjection inside one ASR segment ("I think that would help, yeah" between
    /// the monologue and its resumption) becomes its own turn instead of being
    /// swallowed by whichever speaker dominated the segment as a whole. Falls back
    /// to the whole segment (dominant over its full range, else slot 0) when the
    /// batch ASR gave no word timings to split on.
    private static func remoteAtoms(
        of segment: TranscriptSegment,
        speakers: SpeakerTimeline,
        names: [Int: String]
    ) -> [Atom] {
        func atom(text: String, range: Range<Duration>, words: [WordTiming]) -> Atom {
            // A word inside a turn goes to whoever dominated its window; one that
            // lands in a *gap* (a brief pause no turn covers) goes to the nearest
            // turn in time, not a fixed slot — with identity re-segmentation slot 0
            // is a named person, and a fixed fallback would mislabel every gap word
            // as them (the stray "Theo: what" inside another speaker's section).
            let slot = speakers.dominantSpeaker(in: range)
                ?? speakers.nearestSpeaker(to: range)
                ?? 0
            return Atom(
                label: .remote(slot),
                name: names[slot],
                text: text,
                range: range,
                words: words
            )
        }
        guard !segment.words.isEmpty else {
            return [atom(text: segment.text, range: segment.range, words: [])]
        }
        return segment.words.map { atom(text: $0.text, range: $0.range, words: [$0]) }
    }

    /// A single time-stamped unit the merge sorts and coalesces over: one word
    /// (when timings exist) or a whole segment, tagged with its speaker.
    private struct Atom {
        let label: SpeakerLabel
        let name: String?
        let text: String
        let range: Range<Duration>
        let words: [WordTiming]
    }
}
