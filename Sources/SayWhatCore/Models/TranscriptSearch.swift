import Foundation

/// One occurrence of the search query in a transcript: which entry it landed in
/// and where in that entry's text, as **character offsets**. Offsets (not
/// `String.Index`) so a hit stays meaningful while the live transcript grows —
/// committed text only ever appends, which leaves earlier offsets valid.
public struct TranscriptSearchHit: Sendable, Equatable {
    /// The position of the matched entry in the searched text list.
    public let entry: Int
    /// The matched run within that entry's text, in `Character` offsets.
    public let offsets: Range<Int>

    public init(entry: Int, offsets: Range<Int>) {
        self.entry = entry
        self.offsets = offsets
    }
}

/// Find-in-transcript over the *current* meeting (DESIGN.md §11): the hit list
/// for a query across an ordered list of texts, plus the Find-bar selection —
/// which hit is current, with wraparound next/previous.
///
/// A meeting is a few thousand words, so matching is a plain linear scan on
/// every update — no index. Case- and diacritic-insensitive, so "buoy" finds
/// "Buoy" and "resume" finds "résumé". The caller re-runs ``update(query:texts:)``
/// whenever the query *or* the transcript changes (the live view grows while
/// the Find bar is open); the selection sticks to the same hit when it survives
/// the update rather than snapping back to the first match.
public struct TranscriptSearchState: Sendable, Equatable {
    /// Every match, in transcript order.
    public private(set) var hits: [TranscriptSearchHit] = []
    /// The selected hit's position in ``hits``; `nil` when there are no hits.
    public private(set) var current: Int?
    /// The query the hits were computed for, used to tell "query changed"
    /// (selection resets) from "transcript grew" (selection sticks).
    public private(set) var query = ""

    public init() {}

    /// The selected hit, or `nil` when the query matched nothing.
    public var currentHit: TranscriptSearchHit? {
        current.map { hits[$0] }
    }

    /// The selection as "3 of 12" for the Find bar; `nil` with no hits.
    public var positionLabel: String? {
        current.map { "\($0 + 1) of \(hits.count)" }
    }

    /// Recompute the hits for `query` over `texts` (one string per transcript
    /// entry, in display order). A new query selects the first hit; the same
    /// query keeps the selection on the hit it was on when that hit still
    /// exists (live text appended below it), and otherwise clamps.
    public mutating func update(query: String, texts: [String]) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = currentHit
        let queryChanged = trimmed != self.query
        self.query = trimmed
        hits = Self.matches(of: trimmed, in: texts)
        guard !hits.isEmpty else {
            current = nil
            return
        }
        if !queryChanged, let previous, let kept = hits.firstIndex(of: previous) {
            current = kept
        } else if !queryChanged, let stale = current {
            current = min(stale, hits.count - 1)
        } else {
            current = 0
        }
    }

    /// Select the next hit, wrapping from the last back to the first.
    public mutating func next() {
        guard let current, !hits.isEmpty else { return }
        self.current = (current + 1) % hits.count
    }

    /// Select the previous hit, wrapping from the first back to the last.
    public mutating func previous() {
        guard let current, !hits.isEmpty else { return }
        self.current = (current + hits.count - 1) % hits.count
    }

    /// Every hit in `entry`'s text, for highlighting one rendered block.
    public func offsets(inEntry entry: Int) -> [Range<Int>] {
        hits.filter { $0.entry == entry }.map(\.offsets)
    }

    /// All occurrences of `query` across `texts`, in order. An empty or
    /// whitespace-only query matches nothing (an empty Find field highlighting
    /// the whole transcript helps no one).
    static func matches(of query: String, in texts: [String]) -> [TranscriptSearchHit] {
        guard !query.isEmpty else { return [] }
        var found: [TranscriptSearchHit] = []
        for (entry, text) in texts.enumerated() {
            var from = text.startIndex
            while let range = text.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: from ..< text.endIndex
            ) {
                found.append(TranscriptSearchHit(
                    entry: entry,
                    offsets: text.distance(from: text.startIndex, to: range.lowerBound) ..<
                        text.distance(from: text.startIndex, to: range.upperBound)
                ))
                from = range.upperBound
            }
        }
        return found
    }
}
