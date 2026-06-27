import Foundation

/// A span of recognized speech from one track, at a point in its refinement.
///
/// Live ASR emits each utterance first as **volatile** text — a best guess a
/// later segment may replace — then as **final**, the locked-in transcription.
/// A reader shows volatile text muted and swaps in the final when it arrives.
///
/// ``range`` is measured from the start of the recording session, so segments
/// from the two tracks share one timeline. Per the separate-tracks invariant,
/// ``source`` records which track spoke — the free coarse diarization that
/// later passes refine into per-speaker labels. See DESIGN.md §4, §5.
public struct TranscriptSegment: Sendable, Equatable {
    /// Which track this speech came from.
    public let source: CaptureSource

    /// The recognized text for this span.
    public let text: String

    /// When this speech occurred, relative to the start of the session. May be
    /// empty (`start == end`) for a just-started volatile guess.
    public let range: Range<Duration>

    /// `true` once the recognizer has committed this text; `false` while it is
    /// still a replaceable best guess (see ``isVolatile``).
    public let isFinal: Bool

    /// Per-word timings within this span, when the recognizer provides them
    /// (token-level ASR). Empty otherwise — nothing requires them. See
    /// ``WordTiming``.
    public let words: [WordTiming]

    public init(
        source: CaptureSource,
        text: String,
        range: Range<Duration>,
        isFinal: Bool,
        words: [WordTiming] = []
    ) {
        self.source = source
        self.text = text
        self.range = range
        self.isFinal = isFinal
        self.words = words
    }

    /// `true` while this is an in-progress guess a later segment may replace.
    public var isVolatile: Bool {
        !isFinal
    }

    /// Where this segment begins, relative to the start of the session.
    public var start: Duration {
        range.lowerBound
    }

    /// Where this segment ends, relative to the start of the session.
    public var end: Duration {
        range.upperBound
    }
}
