import Foundation
import Testing
@testable import SayWhatCore

/// The engine-agnostic prompt rendering: compact brief text (D3), the dismissal
/// list, and the delta's place in the pass.
@Suite("LiveBriefPrompt")
struct LiveBriefPromptTests {
    private let brief = LiveBrief(
        nextSteps: [LiveBrief.Item(text: "Fix the importer", speaker: "Alex")],
        openQuestions: [LiveBrief.Item(text: "What about pricing?", resolved: true)]
    )

    @Test("the brief renders compactly: owners, resolution, and empty sections")
    func rendersBrief() {
        let rendered = LiveBriefPrompt.render(brief)

        #expect(rendered == """
        Next steps:
        - Fix the importer (Alex)
        Open questions:
        - What about pricing? [resolved]
        Suggested questions: (none)
        """)
    }

    @Test("the pass prompt carries brief, dismissals, then the delta, labeled")
    func promptLayout() {
        let prompt = LiveBriefPrompt.prompt(
            brief: brief,
            delta: "[1:05] Tom: Let's also update the docs.",
            dismissed: ["Schedule the offsite"]
        )

        #expect(prompt == """
        CURRENT BRIEF:
        \(LiveBriefPrompt.render(brief))

        DISMISSED (do not resurface):
        - Schedule the offsite

        NEW TRANSCRIPT:
        [1:05] Tom: Let's also update the docs.
        """)
    }

    @Test("no dismissals means no DISMISSED block")
    func promptWithoutDismissals() {
        let prompt = LiveBriefPrompt.prompt(
            brief: LiveBrief(),
            delta: "[0:01] You: Hi.",
            dismissed: []
        )

        #expect(!prompt.contains("DISMISSED"))
        #expect(prompt.hasSuffix("NEW TRANSCRIPT:\n[0:01] You: Hi."))
    }

    @Test("the standing instructions state the stability rules")
    func instructions() {
        let text = LiveBriefPrompt.instructions
        #expect(text.contains("mark it resolved"))
        #expect(text.contains("DISMISSED"))
        #expect(text.contains("Never invent"))
    }
}
