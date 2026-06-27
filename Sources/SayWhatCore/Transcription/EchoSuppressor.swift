import Foundation

/// Decides whether a mic segment is just the remote's audio echoing back.
///
/// When the user is on speakers rather than headphones, the remote plays out
/// loud and loops back into the mic, so the mic recognizer transcribes the
/// remote's words and they'd be mislabeled as *you*. This is the pure heuristic
/// that catches that echo — shared by the final-pass ``TranscriptMerger`` (over
/// the whole saved system track) and the live path (over a rolling window of
/// recent remote speech), so both suppress echo the same way. A pragmatic
/// stopgap short of opt-in acoustic echo cancellation (DESIGN.md §5).
///
/// Built once from the remote segments to compare against (their word sets are
/// precomputed), then queried per mic segment.
public struct EchoSuppressor: Sendable {
    /// A remote segment reduced to the inputs the match needs: its time range and
    /// word set.
    private struct Entry {
        let range: Range<Duration>
        let tokens: Set<String>
    }

    private let entries: [Entry]

    /// - Parameter system: remote (system-track) segments to test mic speech
    ///   against. Non-final and punctuation-only segments are ignored.
    public init(system: [TranscriptSegment]) {
        entries = system.filter(\.isFinal).compactMap { segment in
            let tokens = Self.tokens(segment.text)
            guard !tokens.isEmpty else { return nil }
            return Entry(range: segment.range, tokens: tokens)
        }
    }

    /// Whether mic speech over `range` is an acoustic echo of remote speech: a
    /// remote segment overlapping it in time (within ``tolerance``) whose words it
    /// largely repeats. Only a substantial (≥``minWords``) overlap counts, so a
    /// short reply the user genuinely echoes ("yeah", "right") is kept. The text
    /// comparison is a word-set overlap so it tolerates the recognizer hearing the
    /// lower-fidelity echo slightly differently.
    public func isEcho(text: String, range: Range<Duration>) -> Bool {
        let micTokens = Self.tokens(text)
        guard micTokens.count >= Self.minWords else { return false }
        for entry in entries where Self.overlaps(range, entry.range) {
            let denominator = min(micTokens.count, entry.tokens.count)
            guard denominator > 0 else { continue }
            let shared = micTokens.intersection(entry.tokens).count
            if Double(shared) / Double(denominator) >= Self.overlapRatio { return true }
        }
        return false
    }

    /// The fewest mic words an overlap must span to count as echo, so short
    /// genuine replies are never suppressed.
    private static let minWords = 4

    /// The fraction of the shorter segment's words that must match. High enough a
    /// passing shared phrase doesn't trip it, low enough to survive ASR drift on
    /// echoed audio.
    private static let overlapRatio = 0.6

    /// Time slack when matching a mic segment to the remote line it echoes: the
    /// two tracks segment independently (and the echo lags its source), so their
    /// boundaries rarely align to the millisecond.
    private static let tolerance: Duration = .seconds(2)

    /// The lowercased, punctuation-free word set of a string.
    static func tokens(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
    }

    /// Whether two time ranges overlap once each is padded by ``tolerance``.
    private static func overlaps(_ first: Range<Duration>, _ second: Range<Duration>) -> Bool {
        first.lowerBound < second.upperBound + tolerance
            && second.lowerBound < first.upperBound + tolerance
    }
}
