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
/// When the user is on speakers rather than headphones the remote bleeds into
/// the mic, so its words also land on the mic track; the merge suppresses those
/// echoes via ``EchoSuppressor`` so remote speech isn't double-counted as the
/// user's. A pragmatic stopgap short of opt-in acoustic echo cancellation.
///
/// Pure and deterministic: no models, no I/O. The ML adapters that produce its
/// inputs live behind ``Transcriber`` / ``Diarizer``; this is the unit-testable
/// seam where their outputs come together.
public struct TranscriptMerger: Sendable {
    /// A silence between consecutive same-speaker words long enough to end the
    /// current paragraph and start a new (separately timestamped) one.
    private let paragraphPause: Duration
    /// Once a paragraph runs this long, it breaks at the next sentence boundary so
    /// an uninterrupted monologue doesn't render as one unreadable wall of text.
    private let maxParagraph: Duration

    /// - Parameters:
    ///   - paragraphPause: pause between words that starts a new paragraph
    ///     (default 1.5s — comfortably past a between-sentence breath).
    ///   - maxParagraph: soft cap after which a paragraph breaks at the next
    ///     sentence end (default 20s).
    public init(paragraphPause: Duration = .seconds(1.5), maxParagraph: Duration = .seconds(20)) {
        self.paragraphPause = paragraphPause
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
        let suppressor = EchoSuppressor(system: system)

        // Explode every surviving segment into time-stamped atoms (one per word
        // when the batch ASR gave timings, else the whole segment), so a short
        // interjection that lands *inside* a long turn interleaves by time rather
        // than sorting wholesale before or after it. This is what lets a quick
        // "mm-hmm" split a continuous remote monologue into before/you/after.
        var atoms: [Atom] = []
        for segment in mic where segment.isFinal {
            // Drop acoustic echo: the remote played through the speakers and back
            // into the mic, so its words land on the mic track too. Suppressing it
            // per segment keeps a genuine interjection said in the same breath.
            guard !suppressor.isEcho(text: segment.text, range: segment.range) else { continue }
            atoms.append(contentsOf: Self.atoms(of: segment, label: .you, name: nil))
        }
        for segment in system where segment.isFinal {
            atoms.append(contentsOf: Self.remoteAtoms(
                of: segment,
                speakers: remoteSpeakers,
                names: names
            ))
        }
        atoms.sort { $0.range.lowerBound < $1.range.lowerBound }

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
        if atom.range.lowerBound - last.end > paragraphPause { return true }
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
            let slot = speakers.dominantSpeaker(in: range) ?? 0
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

    /// Split a labeled segment into the time-ordered atoms the merge interleaves:
    /// one per word when the segment carries word timings (so another speaker can
    /// break in mid-turn), otherwise the whole segment as a single atom.
    private static func atoms(
        of segment: TranscriptSegment,
        label: SpeakerLabel,
        name: String?
    ) -> [Atom] {
        guard !segment.words.isEmpty else {
            let whole = Atom(
                label: label,
                name: name,
                text: segment.text,
                range: segment.range,
                words: []
            )
            return [whole]
        }
        return segment.words.map { word in
            Atom(label: label, name: name, text: word.text, range: word.range, words: [word])
        }
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
