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
public struct Transcript: Sendable, Equatable {
    /// One speaker's contiguous run of finalized speech.
    public struct Utterance: Sendable, Equatable, Identifiable {
        /// Stable position in the transcript (0-based), usable as a `ForEach` id.
        public let id: Int
        /// Who spoke — channel-coarse (``SpeakerLabel/you``) plus the remote slot
        /// resolved by offline diarization.
        public let speaker: SpeakerLabel
        /// The finalized text for this turn.
        public let text: String
        /// When this turn occurred, relative to the start of the session.
        public let range: Range<Duration>

        public init(id: Int, speaker: SpeakerLabel, text: String, range: Range<Duration>) {
            self.id = id
            self.speaker = speaker
            self.text = text
            self.range = range
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

    /// The end of the last utterance — the transcript's overall length.
    public var duration: Duration {
        utterances.last?.end ?? .zero
    }
}
