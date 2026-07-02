import Foundation

/// One brief entry as the *UI* sees it: a ``LiveBrief/Item`` plus the mechanical
/// attributes the model never touches — a stable identity, the meeting time it
/// appeared (the tap-to-seek anchor), and the user's pin.
public struct BriefItem: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var text: String
    public var speaker: String?
    public var resolved: Bool
    /// Pinned items are never dropped: if a fold pass loses one, the diff
    /// re-asserts it mechanically.
    public var pinned: Bool
    /// Meeting time of the pass that produced (or last changed) this item.
    /// Stamped by the diff layer, never generated — a model would hallucinate it.
    public var at: Duration

    public init(
        id: UUID = UUID(),
        text: String,
        speaker: String? = nil,
        resolved: Bool = false,
        pinned: Bool = false,
        at: Duration = .zero
    ) {
        self.id = id
        self.text = text
        self.speaker = speaker
        self.resolved = resolved
        self.pinned = pinned
        self.at = at
    }

    /// The model-facing shape of this item, for feeding back into the next pass.
    var item: LiveBrief.Item {
        LiveBrief.Item(text: text, speaker: speaker, resolved: resolved)
    }
}

/// The tracked, identified brief — what ``LiveBriefFold`` publishes and the
/// sidebar renders. Section order mirrors ``LiveBrief``.
public struct BriefState: Sendable, Equatable {
    public var nextSteps: [BriefItem] = []
    public var openQuestions: [BriefItem] = []
    public var suggestedQuestions: [BriefItem] = []

    public init() {}

    public var isEmpty: Bool {
        nextSteps.isEmpty && openQuestions.isEmpty && suggestedQuestions.isEmpty
    }

    /// The compact document to hand the model on the next fold pass. Pins and
    /// dismissals are already baked in, so the engine folds from what the user
    /// actually sees.
    public var brief: LiveBrief {
        LiveBrief(
            nextSteps: nextSteps.map(\.item),
            openQuestions: openQuestions.map(\.item),
            suggestedQuestions: suggestedQuestions.map(\.item)
        )
    }

    static var sections: [WritableKeyPath<BriefState, [BriefItem]>] {
        [\.nextSteps, \.openQuestions, \.suggestedQuestions]
    }

    /// Set the pin on the item with `id`, wherever it lives. Unknown ids no-op.
    mutating func setPinned(_ pinned: Bool, id: UUID) {
        for section in Self.sections {
            guard let index = self[keyPath: section].firstIndex(where: { $0.id == id }) else {
                continue
            }
            self[keyPath: section][index].pinned = pinned
            return
        }
    }

    /// Remove and return the item with `id`, wherever it lives; `nil` if absent.
    mutating func remove(id: UUID) -> BriefItem? {
        for section in Self.sections {
            guard let index = self[keyPath: section].firstIndex(where: { $0.id == id }) else {
                continue
            }
            return self[keyPath: section].remove(at: index)
        }
        return nil
    }
}

/// The stability layer between fold passes (docs/live-intelligence.md "UI
/// stability rules"): **diff, don't replace**. Each pass's model output is
/// matched against the previous tracked items by fuzzy text so unchanged items
/// keep their identity and timestamp — only genuine adds/edits/resolutions
/// produce visible change. Pinned items the model dropped are re-asserted;
/// dismissed items never resurface.
enum BriefDiff {
    /// Merge one section: `new` is this pass's model output, `old` the tracked
    /// items it replaces, `time` the meeting time of the pass (stamped onto
    /// anything new or changed). Order follows the model's document; unmatched
    /// pinned items are re-appended untouched; unmatched unpinned items are
    /// dropped — the model's document is authoritative except for pins.
    static func merge(
        old: [BriefItem],
        new: [LiveBrief.Item],
        at time: Duration,
        dismissed: [String]
    ) -> [BriefItem] {
        var unused = old
        var merged: [BriefItem] = new.compactMap { item in
            guard !dismissed.contains(where: { related($0, item.text) }) else { return nil }
            guard let index = unused.firstIndex(where: { related($0.text, item.text) }) else {
                return BriefItem(
                    text: item.text,
                    speaker: item.speaker,
                    resolved: item.resolved,
                    at: time
                )
            }
            var kept = unused.remove(at: index)
            let unchanged = normalize(kept.text) == normalize(item.text)
                && kept.resolved == item.resolved
            kept.text = item.text
            kept.speaker = item.speaker ?? kept.speaker
            kept.resolved = item.resolved
            if !unchanged { kept.at = time }
            return kept
        }
        merged.append(contentsOf: unused.filter(\.pinned))
        return merged
    }

    /// Whether two item texts are the same item, allowing the model's rewording:
    /// equal once normalized, one containing the other, or sharing at least half
    /// their words (Jaccard ≥ 0.5).
    static func related(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalize(lhs)
        let right = normalize(rhs)
        if left == right { return true }
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left.contains(right) || right.contains(left) { return true }
        let leftWords = Set(left.split(separator: " "))
        let rightWords = Set(right.split(separator: " "))
        let union = leftWords.union(rightWords).count
        guard union > 0 else { return false }
        return Double(leftWords.intersection(rightWords).count) / Double(union) >= 0.5
    }

    /// Lowercased, punctuation stripped, whitespace collapsed — the comparison
    /// key for matching items across passes and against the dismissal list.
    static func normalize(_ text: String) -> String {
        String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ")
            .joined(separator: " ")
    }
}
