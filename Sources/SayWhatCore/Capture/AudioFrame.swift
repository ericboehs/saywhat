import Foundation

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

    /// Root-mean-square amplitude of this frame, in `0...1` (linear). Silence is
    /// `0`; a full-scale tone approaches `1`. The natural input to a level meter.
    public var rms: Float {
        guard !samples.isEmpty else { return 0 }
        var sumOfSquares: Float = 0
        for sample in samples {
            sumOfSquares += sample * sample
        }
        return (sumOfSquares / Float(samples.count)).squareRoot()
    }

    /// A meter-friendly level in `0...1`, mapping ``rms`` from `floor` dBFS
    /// (default −60) up to 0 dBFS onto the unit interval. Below the floor reads
    /// `0`; full scale reads `1`. dBFS is used because perceived loudness is
    /// logarithmic, so a linear ``rms`` bar barely twitches for normal speech.
    public func meterLevel(floor: Float = -60) -> Float {
        let amplitude = rms
        guard amplitude > 0, floor < 0 else { return amplitude > 0 ? 1 : 0 }
        let decibels = 20 * log10(amplitude)
        guard decibels > floor else { return 0 }
        return min(1, 1 - decibels / floor)
    }
}
