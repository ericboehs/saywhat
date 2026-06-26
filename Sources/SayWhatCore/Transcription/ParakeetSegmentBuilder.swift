import Foundation

/// One Parakeet token with its time span, relative to the start of the track.
/// A thin, FluidAudio-free mirror of the engine's token timing so the
/// segment-shaping logic below can be unit-tested without loading any model.
public struct TimedToken: Sendable, Equatable {
    /// The raw token text, including the SentencePiece word-start marker `▁`.
    public let text: String
    public let start: Duration
    public let end: Duration

    public init(text: String, start: Duration, end: Duration) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// Shapes a batch Parakeet result into utterance-level final
/// ``TranscriptSegment``s — the pure seam behind ``ParakeetTranscriber``.
///
/// The TDT model emits per-token timings; this groups them into readable,
/// sentence-ish blocks by splitting on speech pauses, reconstructs each block's
/// words from the SentencePiece tokens, and places it on the session timeline.
/// When the model returns no timings it falls back to a single segment spanning
/// the transcribed duration. Deterministic, no I/O — the model-touching code
/// stays in the adapter; this is where its output is tested. DESIGN.md §3, §5.
public struct ParakeetSegmentBuilder: Sendable {
    private let source: CaptureSource
    /// A pause between consecutive tokens that starts a new utterance.
    private let utterancePause: Duration

    public init(source: CaptureSource, utterancePause: Duration = .milliseconds(600)) {
        self.source = source
        self.utterancePause = utterancePause
    }

    /// Build final segments from timed tokens, each offset by `base` (the track's
    /// start on the session timeline). `fallbackText`/`fallbackDuration` are used
    /// only when `tokens` is empty.
    public func segments(
        tokens: [TimedToken],
        fallbackText: String = "",
        fallbackDuration: Duration = .zero,
        base: Duration = .zero
    ) -> [TranscriptSegment] {
        guard !tokens.isEmpty else {
            let text = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            let whole = TranscriptSegment(
                source: source,
                text: text,
                range: base ..< base + fallbackDuration,
                isFinal: true
            )
            return [whole]
        }

        var segments: [TranscriptSegment] = []
        var group: [TimedToken] = []

        func flush() {
            guard let first = group.first, let last = group.last else { return }
            let words = Self.detokenize(group)
            group.removeAll(keepingCapacity: true)
            guard !words.isEmpty else { return }
            segments.append(TranscriptSegment(
                source: source,
                text: words,
                range: base + first.start ..< base + last.end,
                isFinal: true
            ))
        }

        for token in tokens {
            if let previous = group.last, token.start - previous.end > utterancePause {
                flush()
            }
            group.append(token)
        }
        flush()
        return segments
    }

    /// Reconstruct words from SentencePiece-style tokens: `▁` marks a word start,
    /// so it becomes a leading space; the rest concatenate.
    private static func detokenize(_ tokens: [TimedToken]) -> String {
        var text = ""
        for token in tokens {
            text += token.text.replacingOccurrences(of: "\u{2581}", with: " ")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
