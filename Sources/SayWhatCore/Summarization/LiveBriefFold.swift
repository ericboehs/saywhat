import Foundation

/// The stateful heart of live intelligence (docs/live-intelligence.md, Phase
/// L2): accumulates finalized transcript segments, decides when a fold pass is
/// due, runs exactly one ``LiveAnalyst`` generation at a time, and maintains the
/// diffed, identified ``BriefState`` the UI renders.
///
/// Cadence: a pass never runs until `wordFloor` words of new finalized speech
/// have accumulated (word count, not wall clock — silence should not trigger
/// passes), and once past the floor it waits for a natural boundary — a
/// sentence-final segment or a speaker change — rather than firing
/// mid-monologue. Segments that arrive while a pass is in flight coalesce into
/// the next delta; if generation is slower than the cadence, the cadence
/// stretches — never a queue.
///
/// Failures obey the durability posture: a thrown pass is recorded and skipped,
/// its delta re-queued so the next pass simply folds more. Nothing here can
/// touch capture.
public actor LiveBriefFold {
    /// One finalized live segment, as the fold consumes it: plain speaker-
    /// attributed text on the meeting timeline. Volatile text must never be fed
    /// here — it mutates, wasting tokens and flickering the brief.
    public struct Segment: Sendable, Equatable {
        /// The speaker's display name at finalization time ("You", "Alex",
        /// "Speaker 2") — whatever the live pipeline resolved.
        public var speaker: String
        public var text: String
        /// When the segment started, relative to the start of the meeting.
        public var time: Duration

        public init(speaker: String, text: String, time: Duration) {
            self.speaker = speaker
            self.text = text
            self.time = time
        }
    }

    private let analyst: any LiveAnalyst
    private let wordFloor: Int

    private var pending: [Segment] = []
    private var lastFoldedSpeaker: String?
    private var state = BriefState()
    private var dismissed: [String] = []
    private var isFolding = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// Completed fold passes so far — lets a caller detect that the brief
    /// advanced after an `ingest` returned.
    public private(set) var passes = 0
    /// The last pass failure, cleared by the next success. Failures are skipped,
    /// never fatal: the delta stays queued for the next pass.
    public private(set) var lastError: String?
    /// Once finished, the brief is frozen: further segments are ignored.
    public private(set) var isFrozen = false

    /// - Parameters:
    ///   - analyst: the generation engine (Apple FM in production, a scripted
    ///     fake in tests).
    ///   - wordFloor: minimum words of new finalized speech before a pass may
    ///     run. The default approximates 30–45 s of conversation.
    public init(analyst: any LiveAnalyst, wordFloor: Int = 80) {
        self.analyst = analyst
        self.wordFloor = wordFloor
    }

    /// The current diffed brief.
    public func snapshot() -> BriefState {
        state
    }

    /// Feed one finalized segment. Runs a fold pass inline when the cadence gate
    /// opens (so when this returns, `passes`/`snapshot()` reflect it); while a
    /// pass is already in flight the segment just joins the next delta.
    public func ingest(_ segment: Segment) async {
        guard !isFrozen else { return }
        pending.append(segment)
        guard !isFolding else { return }
        await foldWhileReady(force: false)
    }

    /// Meeting end: fold whatever tail remains (regardless of the floor), then
    /// freeze the brief. A failing final pass leaves the last good brief.
    public func finish() async {
        guard !isFrozen else { return }
        await awaitIdle()
        guard !isFrozen else { return }
        await foldWhileReady(force: true)
        isFrozen = true
    }

    /// Pin (or unpin) an item: pinned items survive a model that drops them.
    public func pin(_ id: UUID, pinned: Bool = true) {
        state.setPinned(pinned, id: id)
    }

    /// Dismiss an item: removed now, and suppressed — the engine is told never
    /// to resurface it, and the diff filters it if the model tries anyway.
    public func dismiss(_ id: UUID) {
        guard let removed = state.remove(id: id) else { return }
        dismissed.append(removed.text)
    }

    // MARK: - the fold loop

    /// Run passes until the gate closes (or, when forced, until nothing is
    /// pending). Exactly one loop runs at a time — `ingest` while folding only
    /// appends, and this loop re-checks the gate after each pass, which is what
    /// coalesces segments that arrived mid-generation.
    private func foldWhileReady(force: Bool) async {
        isFolding = true
        defer {
            isFolding = false
            idleWaiters.forEach { $0.resume() }
            idleWaiters.removeAll()
        }
        while !pending.isEmpty, force || gateOpen {
            let delta = pending
            pending = []
            lastFoldedSpeaker = delta.last?.speaker
            let time = delta.last?.time ?? .zero
            do {
                let folded = try await analyst.fold(
                    state.brief,
                    delta: Self.renderDelta(delta),
                    dismissed: dismissed
                )
                apply(folded, at: time)
                passes += 1
                lastError = nil
            } catch {
                pending.insert(contentsOf: delta, at: 0)
                lastError = "\(error)"
                return
            }
        }
    }

    /// Diff-merge one pass's output into the tracked state (identity,
    /// timestamps, pins, dismissals — see ``BriefDiff``).
    private func apply(_ folded: LiveBrief, at time: Duration) {
        let sections: [(WritableKeyPath<BriefState, [BriefItem]>, [LiveBrief.Item])] = [
            (\.nextSteps, folded.nextSteps),
            (\.openQuestions, folded.openQuestions),
            (\.suggestedQuestions, folded.suggestedQuestions),
        ]
        for (section, new) in sections {
            state[keyPath: section] = BriefDiff.merge(
                old: state[keyPath: section],
                new: new,
                at: time,
                dismissed: dismissed
            )
        }
    }

    /// Whether a pass is due: past the word floor *and* at a natural boundary —
    /// the newest segment ended a sentence, or the speaker just changed.
    private var gateOpen: Bool {
        guard pendingWords >= wordFloor, let last = pending.last else { return false }
        if Self.isSentenceFinal(last.text) { return true }
        let previous = pending.count >= 2 ? pending[pending.count - 2].speaker : lastFoldedSpeaker
        return previous != nil && previous != last.speaker
    }

    private var pendingWords: Int {
        pending.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    /// Suspend until no fold loop is running (returns immediately when idle).
    private func awaitIdle() async {
        guard isFolding else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    // MARK: - delta rendering

    /// The transcript delta as the model sees it: one timestamped,
    /// speaker-attributed line per segment.
    static func renderDelta(_ segments: [Segment]) -> String {
        segments
            .map { "[\(timecode($0.time))] \($0.speaker): \($0.text)" }
            .joined(separator: "\n")
    }

    static func isSentenceFinal(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return false
        }
        return ".?!…".contains(last)
    }

    /// `m:ss` on the meeting timeline — the same form the delta lines carry, so
    /// the brief and the transcript read against one clock.
    public static func timecode(_ time: Duration) -> String {
        let seconds = Int(time.components.seconds)
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}
