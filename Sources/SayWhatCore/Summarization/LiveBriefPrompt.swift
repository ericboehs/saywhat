import Foundation

/// The fold prompt: shared, engine-agnostic rendering of one ``LiveAnalyst``
/// pass. The previous brief goes back to the model as **compact rendered text**
/// rather than JSON (docs/live-intelligence.md D3) — cheapest tokens, most
/// natural for the model, and it keeps the whole pass comfortably inside Apple
/// FM's 4096-token window no matter how long the meeting runs.
public enum LiveBriefPrompt {
    /// The standing instructions for every pass. Stability rules live here as
    /// much as in the diff layer: the model is told to carry items forward
    /// verbatim, resolve rather than delete, and never resurface dismissals.
    public static let instructions = """
    You maintain the live brief for a meeting that is still in progress. On each \
    request you get the CURRENT BRIEF and the NEW TRANSCRIPT since the last \
    update (timestamped, speaker-attributed lines; "You" is the user). Return \
    the updated brief.

    Rules:
    - Carry existing items forward with their exact wording unless the new \
    transcript contradicts, changes, or resolves them.
    - Next steps: concrete actions someone agreed to take. Set the speaker to \
    the owner when the transcript makes it clear.
    - Open questions: questions raised but not yet answered. When one gets \
    answered, keep it and mark it resolved — never delete it.
    - Suggested questions: at most three short questions the user would benefit \
    from asking next, grounded in gaps in the discussion.
    - Never invent facts, names, owners, or commitments that are not in the \
    transcript.
    - Keep every item to one short sentence.
    - Never include an item listed under DISMISSED.
    """

    /// The per-pass prompt: previous brief, the dismissal list, then the delta.
    public static func prompt(brief: LiveBrief, delta: String, dismissed: [String]) -> String {
        var parts = ["CURRENT BRIEF:\n\(render(brief))"]
        if !dismissed.isEmpty {
            let list = dismissed.map { "- \($0)" }.joined(separator: "\n")
            parts.append("DISMISSED (do not resurface):\n\(list)")
        }
        parts.append("NEW TRANSCRIPT:\n\(delta)")
        return parts.joined(separator: "\n\n")
    }

    /// The brief as compact text — what the model reads back as its own prior
    /// state, and a reasonable plain-text export of the brief generally.
    public static func render(_ brief: LiveBrief) -> String {
        [
            section("Next steps", brief.nextSteps),
            section("Open questions", brief.openQuestions),
            section("Suggested questions", brief.suggestedQuestions),
        ]
        .joined(separator: "\n")
    }

    private static func section(_ title: String, _ items: [LiveBrief.Item]) -> String {
        guard !items.isEmpty else { return "\(title): (none)" }
        let lines = items.map { item in
            var line = "- \(item.text)"
            if let speaker = item.speaker { line += " (\(speaker))" }
            if item.resolved { line += " [resolved]" }
            return line
        }
        return "\(title):\n" + lines.joined(separator: "\n")
    }
}
