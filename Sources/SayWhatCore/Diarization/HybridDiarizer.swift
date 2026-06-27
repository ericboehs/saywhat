import Foundation

/// A composite ``Diarizer`` for the final pass that takes **turns** from one
/// engine and **voiceprints** from another, fusing them via ``SpeakerTimelineFuser``.
///
/// On real meetings streaming Sortformer splits the remote speakers cleanly but
/// emits no embeddings, while offline pyannote under-segments the turns yet does
/// surface per-cluster embeddings. Wiring Sortformer as `turns` and pyannote as
/// `embeddings` gives the final pass correct who-spoke-when *and* persistent
/// identity, without either engine's weakness (DESIGN.md §6).
///
/// Both sub-diarizers run over the same track, so the incoming single-pass frame
/// stream is buffered once and replayed to each; the engines run sequentially to
/// avoid contending for the Neural Engine. One fused snapshot is emitted at the
/// end (the final pass keeps only the last). The orchestration is exercised with
/// ``Diarizer`` fakes; the real engines live behind the same protocol.
public actor HybridDiarizer: Diarizer {
    private let turns: any Diarizer
    private let embeddings: any Diarizer
    private let fuser = SpeakerTimelineFuser()

    /// - Parameters:
    ///   - turns: the authoritative segmentation/slot source (Sortformer).
    ///   - embeddings: the voiceprint source whose per-cluster embeddings are
    ///     mapped onto `turns`' slots by time overlap (offline pyannote).
    public init(turns: any Diarizer, embeddings: any Diarizer) {
        self.turns = turns
        self.embeddings = embeddings
    }

    public func diarize(
        _ frames: AsyncStream<AudioFrame>
    ) async throws -> AsyncStream<SpeakerTimeline> {
        // Buffer the single-pass stream so both engines see the whole track.
        var buffer: [AudioFrame] = []
        for await frame in frames {
            buffer.append(frame)
        }
        let frozen = buffer

        let turnsTimeline = try await Self.finalSnapshot(of: turns, over: frozen)
        let embeddingTimeline = try await Self.finalSnapshot(of: embeddings, over: frozen)
        let fused = fuser.fuse(turns: turnsTimeline, embeddingSource: embeddingTimeline)

        return AsyncStream { continuation in
            continuation.yield(fused)
            continuation.finish()
        }
    }

    /// Run one sub-diarizer over a replay of the buffered frames and return its
    /// last timeline snapshot (an engine yields progressively; we keep the latest).
    private static func finalSnapshot(
        of diarizer: any Diarizer,
        over frames: [AudioFrame]
    ) async throws -> SpeakerTimeline {
        var timeline = SpeakerTimeline()
        for await snapshot in try await diarizer.diarize(replay(frames)) {
            timeline = snapshot
        }
        return timeline
    }

    /// Replay a buffered frame array as the non-throwing stream the engines consume.
    private static func replay(_ frames: [AudioFrame]) -> AsyncStream<AudioFrame> {
        AsyncStream { continuation in
            for frame in frames {
                continuation.yield(frame)
            }
            continuation.finish()
        }
    }
}
