import Foundation
import Testing
@testable import SayWhatCore

/// The diff layer in isolation: fuzzy matching, timestamp policy, pins,
/// dismissals, and the state's section plumbing.
@Suite("BriefDiff")
struct BriefDiffTests {
    @Test("normalization strips case, punctuation, and extra whitespace")
    func normalization() {
        #expect(BriefDiff.normalize("  Fix the importer!  ") == "fix the importer")
        #expect(BriefDiff.normalize("Fix—the importer?") == "fix the importer")
        #expect(BriefDiff.normalize("!?—").isEmpty)
    }

    @Test("relatedness: exact, containment, and majority word overlap match; disjoint doesn't")
    func relatedness() {
        #expect(BriefDiff.related("Fix the importer.", "fix the importer"))
        #expect(BriefDiff.related("Fix the importer", "Fix the importer before Friday"))
        #expect(BriefDiff.related(
            "Alex will fix the importer bug",
            "Alex should fix the importer bug"
        ))
        #expect(!BriefDiff.related("Fix the importer", "Schedule the offsite"))
        #expect(!BriefDiff.related("Fix the importer", ""))
    }

    @Test("a matched item keeps id and timestamp; a new one is stamped with the pass time")
    func matchAndStamp() {
        let old = [BriefItem(text: "Fix the importer", at: .seconds(10))]
        let merged = BriefDiff.merge(
            old: old,
            new: [
                LiveBrief.Item(text: "Fix the importer"),
                LiveBrief.Item(text: "Schedule the offsite"),
            ],
            at: .seconds(99),
            dismissed: []
        )

        #expect(merged.count == 2)
        #expect(merged[0].id == old[0].id)
        #expect(merged[0].at == .seconds(10))
        #expect(merged[1].at == .seconds(99))
    }

    @Test("a matched item keeps a speaker the model forgot")
    func speakerRetained() {
        let old = [BriefItem(text: "Fix the importer", speaker: "Alex", at: .seconds(10))]
        let merged = BriefDiff.merge(
            old: old,
            new: [LiveBrief.Item(text: "Fix the importer")],
            at: .seconds(99),
            dismissed: []
        )

        #expect(merged.first?.speaker == "Alex")
    }

    @Test("order follows the model's document; each old item matches at most once")
    func orderAndSingleUse() {
        let old = [
            BriefItem(text: "First thing", at: .seconds(1)),
            BriefItem(text: "Second thing", at: .seconds(2)),
        ]
        let merged = BriefDiff.merge(
            old: old,
            new: [
                LiveBrief.Item(text: "Second thing"),
                LiveBrief.Item(text: "First thing"),
            ],
            at: .seconds(9),
            dismissed: []
        )

        #expect(merged.map(\.text) == ["Second thing", "First thing"])
        #expect(Set(merged.map(\.id)) == Set(old.map(\.id)))
    }

    @Test("a dismissed text never re-enters, even reworded")
    func dismissalFilters() {
        let merged = BriefDiff.merge(
            old: [],
            new: [LiveBrief.Item(text: "Fix the importer before Friday")],
            at: .seconds(5),
            dismissed: ["Fix the importer"]
        )

        #expect(merged.isEmpty)
    }

    @Test("unmatched pinned items are re-appended; unmatched unpinned are dropped")
    func pinsReasserted() {
        let pinned = BriefItem(text: "Keep me", pinned: true, at: .seconds(1))
        let loose = BriefItem(text: "Drop me", at: .seconds(2))
        let merged = BriefDiff.merge(
            old: [pinned, loose],
            new: [],
            at: .seconds(9),
            dismissed: []
        )

        #expect(merged == [pinned])
    }

    @Test("state round-trips to the model-facing brief, pins included")
    func stateToBrief() {
        var state = BriefState()
        state.nextSteps = [BriefItem(text: "Fix the importer", speaker: "Alex", pinned: true)]
        state.openQuestions = [BriefItem(text: "What about pricing?", resolved: true)]

        let brief = state.brief
        #expect(brief.nextSteps == [LiveBrief.Item(text: "Fix the importer", speaker: "Alex")])
        let expected = LiveBrief.Item(text: "What about pricing?", resolved: true)
        #expect(brief.openQuestions == [expected])
        #expect(brief.suggestedQuestions.isEmpty)
        #expect(!brief.isEmpty)
        #expect(LiveBrief().isEmpty)
    }

    @Test("pin and remove address an item in any section; unknown ids no-op")
    func statePlumbing() {
        var state = BriefState()
        let question = BriefItem(text: "What about pricing?")
        state.suggestedQuestions = [question]

        state.setPinned(true, id: question.id)
        #expect(state.suggestedQuestions.first?.pinned == true)
        state.setPinned(false, id: UUID()) // unknown — untouched
        #expect(state.suggestedQuestions.first?.pinned == true)

        #expect(state.remove(id: UUID()) == nil)
        #expect(state.remove(id: question.id)?.text == "What about pricing?")
        #expect(state.isEmpty)
    }
}
