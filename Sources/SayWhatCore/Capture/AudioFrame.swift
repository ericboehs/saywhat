/// A timestamped block of mono 16 kHz Float32 PCM — the unit both the live ML
/// pipeline and the AAC encoder consume. Carries its ``CaptureSource`` so the
/// two tracks are never confused downstream (the separate-tracks invariant).
public struct AudioFrame: Sendable, Equatable {
    /// Which track this audio came from.
    public let source: CaptureSource

    /// Offset of this frame's first sample from the start of the session.
    public let startOffset: Duration

    /// Mono 32-bit float samples at ``AudioStreamFormat/model`` rate.
    public let samples: [Float]

    public init(source: CaptureSource, startOffset: Duration, samples: [Float]) {
        self.source = source
        self.startOffset = startOffset
        self.samples = samples
    }

    /// Duration of this frame at the model sample rate.
    public var duration: Duration {
        .seconds(Double(samples.count) / Double(AudioStreamFormat.model.sampleRate))
    }
}
