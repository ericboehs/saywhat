import Foundation

/// Sums the mic and system tracks into one stream for the **live transcript
/// only**. Capture and storage stay fully separate (the core invariant, so the
/// final pass still diarizes off clean per-channel audio); this mono mix exists
/// solely so a *single* recognizer drives the live view.
///
/// Why mix at all: the speaker's audio leaks into the mic, so two per-track
/// recognizers each transcribe it — once clean (system), once as echo (mic).
/// Summing collapses that to one stream: the echo and its source are the same
/// sound at nearly the same time, so one recognizer hears one utterance. No
/// dedupe heuristic, and nothing ever appears then gets retracted on screen.
/// The trade is live speaker separation (low value in a 5–10 person meeting)
/// and some accuracy loss when both tracks talk at once. See DESIGN.md §5.
public actor AudioMixer {
    private var buffer = MixBuffer()
    private var emittedSamples = 0
    private var continuation: AsyncStream<AudioFrame>.Continuation?
    private var stream: AsyncStream<AudioFrame>?

    public init() {}

    /// The mixed stream. Call once, before feeding, so emitted audio has a sink.
    public func output() -> AsyncStream<AudioFrame> {
        if let stream { return stream }
        let (made, continuation) = AsyncStream<AudioFrame>.makeStream()
        stream = made
        self.continuation = continuation
        return made
    }

    /// Add one track's freshly-captured samples (16 kHz mono model format).
    public func feed(_ source: CaptureSource, _ samples: [Float]) {
        switch source {
        case .microphone: buffer.appendMic(samples)
        case .system: buffer.appendSystem(samples)
        }
        emitReady()
    }

    /// Mark one track ended. When both have ended and the buffer is drained, the
    /// mixed stream finishes so its consumer (the transcriber) can wind down.
    public func finish(_ source: CaptureSource) {
        switch source {
        case .microphone: buffer.finishMic()
        case .system: buffer.finishSystem()
        }
        emitReady()
        if buffer.isComplete {
            continuation?.finish()
            continuation = nil
        }
    }

    private func emitReady() {
        guard let continuation else { return }
        let ready = buffer.drain()
        guard !ready.isEmpty else { return }
        let offset = Duration.seconds(
            Double(emittedSamples) / Double(AudioStreamFormat.model.sampleRate)
        )
        emittedSamples += ready.count
        // The mixed frame's source label is nominal — the transcriber tags
        // segments from its own configured source, and the live view ignores it.
        continuation.yield(AudioFrame(source: .microphone, startOffset: offset, samples: ready))
    }
}

/// The pure summing core behind ``AudioMixer``: two FIFO sample queues summed
/// pairwise as both fill. Both tracks are continuous 16 kHz streams that start
/// together (within ~0.1 s, well inside the echo delay), so sample *k* of one
/// lines up with sample *k* of the other — a positional pair-and-sum is enough;
/// no per-sample timestamp bookkeeping. Kept separate from the actor so the
/// alignment logic is unit-tested without stream plumbing.
struct MixBuffer {
    private var mic: [Float] = []
    private var system: [Float] = []
    private var micDone = false
    private var systemDone = false

    mutating func appendMic(_ samples: [Float]) {
        mic.append(contentsOf: samples)
    }

    mutating func appendSystem(_ samples: [Float]) {
        system.append(contentsOf: samples)
    }

    mutating func finishMic() {
        micDone = true
    }

    mutating func finishSystem() {
        systemDone = true
    }

    /// Everything ready to emit: pairwise sums where both queues have data, plus
    /// a tail flush of whichever side outlives the other once that other has
    /// ended (so the last samples aren't stranded waiting for a pair).
    mutating func drain() -> [Float] {
        let paired = min(mic.count, system.count)
        var out: [Float] = []
        if paired > 0 {
            out.reserveCapacity(paired)
            for index in 0 ..< paired {
                out.append(Self.mix(mic[index], system[index]))
            }
            mic.removeFirst(paired)
            system.removeFirst(paired)
        }
        // Pairing emptied at least one queue; flush the survivor if its
        // counterpart is finished (no more pairs will ever come).
        if systemDone, !mic.isEmpty {
            out.append(contentsOf: mic)
            mic.removeAll()
        }
        if micDone, !system.isEmpty {
            out.append(contentsOf: system)
            system.removeAll()
        }
        return out
    }

    /// Both tracks ended and everything has been drained.
    var isComplete: Bool {
        micDone && systemDone && mic.isEmpty && system.isEmpty
    }

    /// Sum with a hard clip guard. Echo is attenuated and the two rarely peak at
    /// once, so clipping is rare; the recognizer tolerates it regardless.
    private static func mix(_ lhs: Float, _ rhs: Float) -> Float {
        max(-1, min(1, lhs + rhs))
    }
}
