import Foundation

/// The authoritative, finalized transcript of a meeting: an ordered list of
/// speaker-attributed utterances produced by the **final pass** (batch ASR +
/// offline diarization + identity resolution).
///
/// Unlike the live ``LiveTranscript`` shown while recording, this is the canonical
/// record — immutable, nothing volatile. Every utterance carries a resolved
/// ``SpeakerLabel`` and a time range on the session timeline, and consecutive
/// utterances from the same speaker are coalesced into one block. See DESIGN.md
/// §3 (two pipelines) and §5.
public struct Transcript: Sendable, Equatable, Codable {
    /// One speaker's contiguous run of finalized speech.
    public struct Utterance: Sendable, Equatable, Codable, Identifiable {
        /// Stable position in the transcript (0-based), usable as a `ForEach` id.
        public let id: Int
        /// Who spoke — channel-coarse (``SpeakerLabel/you``) plus the remote slot
        /// resolved by offline diarization.
        public let speaker: SpeakerLabel
        /// The persistent identity resolved for this turn (e.g. "Eric"), when a
        /// ``Voiceprint`` matched; `nil` falls back to the slot's generic label.
        public let speakerName: String?
        /// The finalized text for this turn.
        public let text: String
        /// When this turn occurred, relative to the start of the session.
        public let range: Range<Duration>
        /// Per-word timings spanning this turn, in order, when the batch ASR
        /// provided them — drives word-level playback highlighting. Empty
        /// otherwise. See ``WordTiming``.
        public let words: [WordTiming]

        public init(
            id: Int,
            speaker: SpeakerLabel,
            speakerName: String? = nil,
            text: String,
            range: Range<Duration>,
            words: [WordTiming] = []
        ) {
            self.id = id
            self.speaker = speaker
            self.speakerName = speakerName
            self.text = text
            self.range = range
            self.words = words
        }

        /// Where this turn begins, relative to the start of the session.
        public var start: Duration {
            range.lowerBound
        }

        /// Where this turn ends, relative to the start of the session.
        public var end: Duration {
            range.upperBound
        }
    }

    public private(set) var utterances: [Utterance]

    public init(utterances: [Utterance] = []) {
        self.utterances = utterances
    }

    public var isEmpty: Bool {
        utterances.isEmpty
    }

    /// A copy with every turn from remote `slot` relabeled to `name` — the
    /// speaker's persistent identity just changed (the user named them). Turns
    /// from other speakers are untouched; ids, text, and timings are preserved.
    ///
    /// When another remote slot already shows `name` — i.e. the diarizer split one
    /// person into two slots and the user is naming the second the same — this
    /// slot's turns **adopt that slot's color**, so the merged speaker reads in one
    /// color throughout (matching the single-segment ``reassigningUtterance(_:to:)``;
    /// the caller binds both slots' voiceprints to the one person). Renaming to a
    /// fresh name keeps the slot's current color.
    public func renamingSpeaker(_ slot: Int, to name: String) -> Transcript {
        let adopted = utterances.first {
            $0.speaker != .remote(slot) && $0.speaker.remoteSlot != nil && $0.speakerName == name
        }?.speaker
        return Transcript(utterances: utterances.map { utterance in
            guard utterance.speaker == .remote(slot) else { return utterance }
            return Utterance(
                id: utterance.id,
                speaker: adopted ?? utterance.speaker,
                speakerName: name,
                text: utterance.text,
                range: utterance.range,
                words: utterance.words
            )
        })
    }

    /// A copy with the single utterance `id` reassigned to `name` — correcting one
    /// segment the diarizer mis-grouped, without touching the rest of its group
    /// (the whole-group ``renamingSpeaker(_:to:)`` is the default; this is the
    /// surgical override). The segment also adopts the color/slot of any other
    /// remote block already shown under `name`, so the same person reads in one
    /// color throughout; a brand-new name keeps the segment's current color. Ids,
    /// text, and timings are preserved.
    public func reassigningUtterance(_ id: Int, to name: String) -> Transcript {
        let adopted = utterances.first {
            $0.speakerName == name && $0.speaker.remoteSlot != nil
        }?.speaker
        return Transcript(utterances: utterances.map { utterance in
            guard utterance.id == id else { return utterance }
            return Utterance(
                id: utterance.id,
                speaker: adopted ?? utterance.speaker,
                speakerName: name,
                text: utterance.text,
                range: utterance.range,
                words: utterance.words
            )
        })
    }

    /// The end of the last utterance — the transcript's overall length.
    public var duration: Duration {
        utterances.last?.end ?? .zero
    }

    /// Identifies one word in the transcript: its utterance and the word's index
    /// within that utterance's ``Utterance/words``.
    public struct WordCursor: Sendable, Equatable {
        /// The ``Utterance/id`` of the utterance the word belongs to.
        public let utteranceID: Int
        /// The word's position within that utterance's word timings.
        public let wordIndex: Int

        public init(utteranceID: Int, wordIndex: Int) {
            self.utteranceID = utteranceID
            self.wordIndex = wordIndex
        }
    }

    /// The word to highlight at `time` on the session timeline, for karaoke-style
    /// playback: the latest word that has started at or before `time`. It stays lit
    /// through any gap until the next word begins, so the highlight never flickers
    /// off mid-sentence. `nil` before the first word starts, or when no utterance
    /// carries word timings (the batch ASR gave none). See ``WordTiming``.
    public func wordCursor(at time: Duration) -> WordCursor? {
        var cursor: WordCursor?
        for utterance in utterances {
            for (index, word) in utterance.words.enumerated() where word.range.lowerBound <= time {
                cursor = WordCursor(utteranceID: utterance.id, wordIndex: index)
            }
        }
        return cursor
    }
}
