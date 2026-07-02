import Foundation

/// The rolling in-meeting brief a ``LiveAnalyst`` maintains — the *fold document*
/// the model reads back and rewrites on every pass (docs/live-intelligence.md).
///
/// This is the model-facing shape: plain items with no identity or timestamps.
/// Identity, timestamps, pins, and dismissals are mechanical concerns layered on
/// by ``LiveBriefFold``/``BriefState`` — the model would hallucinate timestamps
/// and drop pins, so it is never asked to manage them.
public struct LiveBrief: Sendable, Equatable, Codable {
    /// One entry in a brief section.
    public struct Item: Sendable, Equatable, Codable {
        /// The item itself — one short sentence.
        public var text: String
        /// Who said or owns it, when the transcript makes that clear.
        public var speaker: String?
        /// Answered / done. Resolved items are kept, not deleted — they render
        /// struck-through so the meeting keeps its shape.
        public var resolved: Bool

        public init(text: String, speaker: String? = nil, resolved: Bool = false) {
            self.text = text
            self.speaker = speaker
            self.resolved = resolved
        }
    }

    /// Action items as they're agreed, with owner when known.
    public var nextSteps: [Item]
    /// Questions raised but not yet answered; answered ones flip to resolved.
    public var openQuestions: [Item]
    /// Things the model thinks *you* might want to ask next.
    public var suggestedQuestions: [Item]

    public init(
        nextSteps: [Item] = [],
        openQuestions: [Item] = [],
        suggestedQuestions: [Item] = []
    ) {
        self.nextSteps = nextSteps
        self.openQuestions = openQuestions
        self.suggestedQuestions = suggestedQuestions
    }

    public var isEmpty: Bool {
        nextSteps.isEmpty && openQuestions.isEmpty && suggestedQuestions.isEmpty
    }
}
