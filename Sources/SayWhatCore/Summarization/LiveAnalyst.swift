import Foundation

/// The in-meeting analysis engine: one **fold pass** over the live transcript
/// (docs/live-intelligence.md).
///
/// Deliberately *not* ``Summarizer``-shaped — that contract is a one-shot
/// `transcript → notes` over a finished meeting. The analyst is a stateful fold:
/// it is handed the previous brief plus only the transcript **delta** since the
/// last pass, and returns the updated brief. The prompt is therefore bounded no
/// matter how long the meeting runs — which is what makes a 4k-context model
/// (Apple FM on the ANE) viable live.
///
/// Cadence, delta accumulation, serialization, diffing, and pin/dismiss all live
/// in ``LiveBriefFold``; an engine only ever sees one self-contained call. Unit
/// tests script this protocol with a deterministic fake — no CoreML in tests,
/// same pattern as the diarization suite.
public protocol LiveAnalyst: Sendable {
    /// Fold `delta` (rendered transcript lines — timestamped, speaker-attributed)
    /// into `brief`, returning the updated brief. `dismissed` lists item texts the
    /// user dismissed; the engine must not resurface them. A thrown error skips
    /// the pass — the caller re-queues the delta, so the next pass folds more.
    func fold(_ brief: LiveBrief, delta: String, dismissed: [String]) async throws -> LiveBrief
}
