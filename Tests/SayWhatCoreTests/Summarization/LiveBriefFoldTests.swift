import Foundation
import Testing
@testable import SayWhatCore

/// A deterministic ``LiveAnalyst``: returns scripted briefs (or failures) in
/// order, recording every call. Off-script calls echo the brief back.
private actor ScriptedAnalyst: LiveAnalyst {
    enum Step {
        case produce(LiveBrief)
        case fail
    }

    struct Failure: Error {}

    struct Call: Equatable {
        var brief: LiveBrief
        var delta: String
        var dismissed: [String]
    }

    private var steps: [Step]
    private(set) var calls: [Call] = []

    init(_ steps: Step...) {
        self.steps = steps
    }

    func fold(_ brief: LiveBrief, delta: String, dismissed: [String]) async throws -> LiveBrief {
        calls.append(Call(brief: brief, delta: delta, dismissed: dismissed))
        guard !steps.isEmpty else { return brief }
        switch steps.removeFirst() {
        case let .produce(brief): return brief
        case .fail: throw Failure()
        }
    }
}

/// An engine that suspends every fold until the test releases it, exposing the
/// in-flight window.
private actor BlockingAnalyst: LiveAnalyst {
    private var waiters: [CheckedContinuation<LiveBrief, Never>] = []
    private(set) var deltas: [String] = []

    var inFlight: Int {
        waiters.count
    }

    func fold(_: LiveBrief, delta: String, dismissed _: [String]) async throws -> LiveBrief {
        deltas.append(delta)
        return await withCheckedContinuation { waiters.append($0) }
    }

    func release(_ brief: LiveBrief) {
        waiters.removeFirst().resume(returning: brief)
    }
}

private func segment(
    _ speaker: String,
    _ text: String,
    at seconds: Int = 0
) -> LiveBriefFold.Segment {
    LiveBriefFold.Segment(speaker: speaker, text: text, time: .seconds(seconds))
}

private func brief(nextStep text: String, speaker: String? = nil) -> LiveBrief {
    LiveBrief(nextSteps: [LiveBrief.Item(text: text, speaker: speaker)])
}

/// The fold actor's contract (docs/live-intelligence.md, Phase L2): cadence
/// gating, delta accumulation and coalescing, one pass in flight, diff-driven
/// stability, pins, dismissals, failure skipping, and the end-of-meeting
/// freeze. The engine is scripted — no models in tests.
@Suite("LiveBriefFold — cadence and delta")
struct LiveBriefFoldCadenceTests {
    @Test("no pass runs below the word floor, even at a sentence boundary")
    func floorGates() async {
        let analyst = ScriptedAnalyst()
        let fold = LiveBriefFold(analyst: analyst, wordFloor: 10)

        await fold.ingest(segment("Alex", "Ship it today.", at: 5))

        #expect(await fold.passes == 0)
        #expect(await analyst.calls.isEmpty)
    }

    @Test("past the floor, a sentence-final segment fires a pass with the whole delta")
    func firesAtSentenceBoundary() async {
        let analyst = ScriptedAnalyst()
        let fold = LiveBriefFold(analyst: analyst, wordFloor: 6)

        await fold.ingest(segment("Alex", "We need to fix the importer", at: 61))
        #expect(await fold.passes == 0)
        await fold.ingest(segment("Alex", "before the demo on Friday.", at: 65))

        #expect(await fold.passes == 1)
        let call = await analyst.calls.first
        #expect(call?.delta == """
        [1:01] Alex: We need to fix the importer
        [1:05] Alex: before the demo on Friday.
        """)
        #expect(call?.brief == LiveBrief())
    }

    @Test("past the floor mid-monologue it holds; a speaker change fires it")
    func firesAtSpeakerChange() async {
        let analyst = ScriptedAnalyst()
        let fold = LiveBriefFold(analyst: analyst, wordFloor: 4)

        await fold.ingest(segment("Alex", "so the other thing we should probably"))
        #expect(await fold.passes == 0) // past the floor, but mid-sentence, same speaker
        await fold.ingest(segment("Tom", "right, agreed"))

        #expect(await fold.passes == 1)
    }

    @Test("the delta resets after a pass and the updated brief feeds the next one")
    func deltaResets() async {
        let first = brief(nextStep: "Fix the importer", speaker: "Alex")
        let analyst = ScriptedAnalyst(.produce(first))
        let fold = LiveBriefFold(analyst: analyst, wordFloor: 3)

        await fold.ingest(segment("Alex", "Please fix the importer."))
        await fold.ingest(segment("Tom", "I will also update the docs."))

        #expect(await fold.passes == 2)
        let calls = await analyst.calls
        #expect(calls.last?.delta == "[0:00] Tom: I will also update the docs.")
        #expect(calls.last?.brief == first)
    }

    @Test("a failed pass is skipped and its delta re-queued for the next one")
    func failureRequeuesDelta() async {
        let analyst = ScriptedAnalyst(.fail, .produce(brief(nextStep: "Fix the importer")))
        let fold = LiveBriefFold(analyst: analyst, wordFloor: 3)

        await fold.ingest(segment("Alex", "Please fix the importer.", at: 10))
        #expect(await fold.passes == 0)
        #expect(await fold.lastError != nil)

        await fold.ingest(segment("Tom", "Yes, please do."))

        #expect(await fold.passes == 1)
        #expect(await fold.lastError == nil)
        let delta = await analyst.calls.last?.delta
        #expect(delta == """
        [0:10] Alex: Please fix the importer.
        [0:00] Tom: Yes, please do.
        """)
    }

    @Test("segments arriving mid-pass coalesce into the next delta — one pass in flight")
    func coalescesWhileFolding() async {
        let analyst = BlockingAnalyst()
        let fold = LiveBriefFold(analyst: analyst, wordFloor: 2)

        let first = Task { await fold.ingest(segment("Alex", "Ship the fix today.", at: 1)) }
        while await analyst.inFlight == 0 {
            await Task.yield()
        }

        // Two more finalize while the pass runs; they only accumulate.
        await fold.ingest(segment("Tom", "And update the changelog.", at: 2))
        await fold.ingest(segment("Tom", "Then tell the team.", at: 3))
        #expect(await fold.passes == 0)
        #expect(await analyst.deltas.count == 1)

        await analyst.release(LiveBrief())
        // The same loop picks up the coalesced delta as its next (blocked) pass.
        while await analyst.deltas.count < 2 {
            await Task.yield()
        }
        await analyst.release(LiveBrief())
        await first.value

        #expect(await fold.passes == 2)
        #expect(await analyst.deltas.last == """
        [0:02] Tom: And update the changelog.
        [0:03] Tom: Then tell the team.
        """)
    }

    @Test("finish folds the below-floor tail, then freezes the brief")
    func finishFoldsTailAndFreezes() async {
        let analyst = ScriptedAnalyst(.produce(brief(nextStep: "Send the notes")))
        let fold = LiveBriefFold(analyst: analyst, wordFloor: 50)

        await fold.ingest(segment("Alex", "Send the notes after."))
        #expect(await fold.passes == 0)
        await fold.finish()

        #expect(await fold.passes == 1)
        #expect(await fold.isFrozen)
        #expect(await fold.snapshot().nextSteps.map(\.text) == ["Send the notes"])

        await fold.ingest(segment("Tom", "One more thing, with many words to spare."))
        await fold.finish()
        #expect(await fold.passes == 1) // frozen: ignored
    }

    @Test("finish with nothing pending freezes without a pass")
    func finishEmpty() async {
        let analyst = ScriptedAnalyst()
        let fold = LiveBriefFold(analyst: analyst, wordFloor: 2)

        await fold.finish()

        #expect(await fold.passes == 0)
        #expect(await fold.isFrozen)
    }

    @Test("sentence-final detection tolerates trailing whitespace and ellipses")
    func sentenceFinal() {
        #expect(LiveBriefFold.isSentenceFinal("Done."))
        #expect(LiveBriefFold.isSentenceFinal("Really? "))
        #expect(LiveBriefFold.isSentenceFinal("Go!"))
        #expect(LiveBriefFold.isSentenceFinal("well…"))
        #expect(!LiveBriefFold.isSentenceFinal("and then we"))
        #expect(!LiveBriefFold.isSentenceFinal("   "))
    }

    @Test("timecodes render minutes:seconds on the meeting clock")
    func timecodes() {
        #expect(LiveBriefFold.timecode(.zero) == "0:00")
        #expect(LiveBriefFold.timecode(.seconds(65)) == "1:05")
        #expect(LiveBriefFold.timecode(.seconds(3599)) == "59:59")
    }
}

/// The UI stability rules: diff-preserved identity, restamping, resolution,
/// pins, and dismissal suppression.
@Suite("LiveBriefFold — stability")
struct LiveBriefFoldStabilityTests {
    @Test("an item the model carries forward keeps its identity and timestamp")
    func diffKeepsIdentity() async {
        let step = brief(nextStep: "Fix the importer")
        let analyst = ScriptedAnalyst(.produce(step), .produce(step))
        let fold = LiveBriefFold(analyst: analyst, wordFloor: 3)

        await fold.ingest(segment("Alex", "Please fix the importer.", at: 10))
        let before = await fold.snapshot().nextSteps
        await fold.ingest(segment("Tom", "And there is more to discuss.", at: 90))

        #expect(await fold.snapshot().nextSteps == before)
        #expect(before.first?.at == .seconds(10))
    }

    @Test("a reworded item keeps its id but is restamped to the newer pass")
    func rewordKeepsID() async {
        let analyst = ScriptedAnalyst(
            .produce(brief(nextStep: "Fix the importer")),
            .produce(brief(nextStep: "Fix the importer before Friday"))
        )
        let fold = LiveBriefFold(analyst: analyst, wordFloor: 3)

        await fold.ingest(segment("Alex", "Please fix the importer.", at: 10))
        let original = await fold.snapshot().nextSteps.first
        await fold.ingest(segment("Alex", "It must land before Friday.", at: 90))

        let reworded = await fold.snapshot().nextSteps.first
        #expect(reworded?.id == original?.id)
        #expect(reworded?.text == "Fix the importer before Friday")
        #expect(reworded?.at == .seconds(90))
    }

    @Test("a resolved question is kept and marked, never deleted")
    func resolvedKept() async {
        let question = LiveBrief.Item(text: "What about pricing?", speaker: "Tom")
        var answered = question
        answered.resolved = true
        let analyst = ScriptedAnalyst(
            .produce(LiveBrief(openQuestions: [question])),
            .produce(LiveBrief(openQuestions: [answered]))
        )
        let fold = LiveBriefFold(analyst: analyst, wordFloor: 3)

        await fold.ingest(segment("Tom", "What about pricing though?", at: 10))
        let asked = await fold.snapshot().openQuestions.first
        await fold.ingest(segment("Alex", "Pricing stays the same this year.", at: 45))

        let resolved = await fold.snapshot().openQuestions.first
        #expect(resolved?.id == asked?.id)
        #expect(resolved?.resolved == true)
        #expect(resolved?.at == .seconds(45)) // resolution restamps: "answered at"
    }

    @Test("a pinned item survives a pass whose model output drops it")
    func pinnedSurvives() async {
        let analyst = ScriptedAnalyst(
            .produce(brief(nextStep: "Fix the importer")),
            .produce(LiveBrief()) // the model loses everything
        )
        let fold = LiveBriefFold(analyst: analyst, wordFloor: 3)

        await fold.ingest(segment("Alex", "Please fix the importer."))
        let item = await fold.snapshot().nextSteps.first
        #expect(item != nil)
        if let item { await fold.pin(item.id) }
        await fold.ingest(segment("Tom", "Moving on to something else."))

        let kept = await fold.snapshot().nextSteps
        #expect(kept.map(\.id) == [item?.id])
        #expect(kept.first?.pinned == true)
        // The pinned item also rides back to the model as part of its own state.
        #expect(await analyst.calls.last?.brief.nextSteps.isEmpty == false)
    }

    @Test("an unpinned item the model drops is gone — its document is authoritative")
    func unpinnedDropped() async {
        let analyst = ScriptedAnalyst(
            .produce(brief(nextStep: "Fix the importer")),
            .produce(LiveBrief())
        )
        let fold = LiveBriefFold(analyst: analyst, wordFloor: 3)

        await fold.ingest(segment("Alex", "Please fix the importer."))
        await fold.ingest(segment("Tom", "Actually, never mind that."))

        #expect(await fold.snapshot().nextSteps.isEmpty)
    }

    @Test("a dismissed item is suppressed: told to the engine, filtered if it returns")
    func dismissedSuppressed() async {
        let step = brief(nextStep: "Fix the importer")
        let analyst = ScriptedAnalyst(.produce(step), .produce(step))
        let fold = LiveBriefFold(analyst: analyst, wordFloor: 3)

        await fold.ingest(segment("Alex", "Please fix the importer."))
        if let item = await fold.snapshot().nextSteps.first {
            await fold.dismiss(item.id)
        }
        #expect(await fold.snapshot().nextSteps.isEmpty)
        await fold.ingest(segment("Tom", "Someone should fix that importer."))

        #expect(await analyst.calls.last?.dismissed == ["Fix the importer"])
        #expect(await fold.snapshot().nextSteps.isEmpty) // re-emitted; the diff filters it
    }
}
