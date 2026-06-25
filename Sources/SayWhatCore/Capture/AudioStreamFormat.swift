/// The PCM format every ASR and diarization model in SayWhat expects: 16 kHz,
/// mono, 32-bit float. Capture converts both tracks to this for the live
/// pipeline (storage uses AAC separately). See DESIGN.md §4.
public struct AudioStreamFormat: Sendable, Equatable {
    /// Samples per second, per channel.
    public let sampleRate: Int

    /// Number of interleaved channels.
    public let channelCount: Int

    public init(sampleRate: Int, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    /// 16 kHz mono — the canonical model input format.
    public static let model = AudioStreamFormat(sampleRate: 16000, channelCount: 1)

    /// Sample count (per channel) in `duration` of audio at this rate.
    public func sampleCount(for duration: Duration) -> Int {
        let comps = duration.components
        let seconds = Double(comps.seconds) + Double(comps.attoseconds) / 1e18
        return Int((seconds * Double(sampleRate)).rounded())
    }
}
