import Foundation

/// One recognized word and the span of audio it was spoken over, on the session
/// timeline (the same clock as ``TranscriptSegment/range``).
///
/// Token-level ASR (FluidAudio Parakeet TDT, Apple `SpeechTranscriber`) can
/// timestamp each word, not just the utterance. Carrying those lets playback
/// highlight the word under the playhead — karaoke-style — rather than the whole
/// turn. A transcriber that can't provide them simply leaves
/// ``TranscriptSegment/words`` empty; nothing downstream requires them.
public struct WordTiming: Sendable, Equatable {
    /// The recognized word, as it should be shown.
    public let text: String

    /// When the word was spoken, relative to the start of the session.
    public let range: Range<Duration>

    public init(text: String, range: Range<Duration>) {
        self.text = text
        self.range = range
    }
}
