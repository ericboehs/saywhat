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
            let text = Self.detokenize(group)
            let words = Self.words(group, base: base)
            group.removeAll(keepingCapacity: true)
            guard !text.isEmpty else { return }
            segments.append(TranscriptSegment(
                source: source,
                text: text,
                range: base + first.start ..< base + last.end,
                isFinal: true,
                words: words
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

    /// Group tokens into per-word ``WordTiming``s for karaoke-style playback
    /// highlighting. A `▁`-prefixed token starts a new word; trailing tokens (e.g.
    /// `▁play`, `ing`) fold into it. Each word spans from its first token's start
    /// to its last token's end, offset by `base` onto the session timeline.
    private static func words(_ tokens: [TimedToken], base: Duration) -> [WordTiming] {
        var words: [WordTiming] = []
        var text = ""
        var start: Duration = .zero
        var end: Duration = .zero

        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                words.append(WordTiming(text: trimmed, range: base + start ..< base + end))
            }
            text = ""
        }

        for token in tokens {
            let piece = token.text.replacingOccurrences(of: "\u{2581}", with: "")
            if token.text.hasPrefix("\u{2581}"), !text.isEmpty {
                flush()
            }
            if text.isEmpty {
                start = token.start
            }
            text += piece
            end = token.end
        }
        flush()
        return words
    }
}
