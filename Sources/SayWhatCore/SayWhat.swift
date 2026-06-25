import Foundation

/// SayWhat — on-device meeting recorder, real-time transcriber, speaker
/// diarizer, and summarizer for Apple Silicon Macs.
///
/// `SayWhatCore` holds the pure, hardware-free logic and shared value types that
/// the app and engines build on. Keeping it free of `AVFoundation` /
/// `ScreenCaptureKit` / model dependencies is what makes it unit-testable
/// without hardware (QUALITY.md §5).
///
/// > Note: **Phase 0 placeholder.** This module currently exposes only a version
/// > marker and a timecode helper so the build, test, and coverage gates are
/// > exercised from the first commit. The real types — capture, transcription,
/// > diarization, summarization, storage — arrive per DESIGN.md §14.
public enum SayWhat {
    /// Semantic version of the core module. Pre-implementation until Phase 0.
    public static let version = "0.0.0"

    /// Formats a duration in whole seconds for transcript timestamps:
    /// `M:SS` under an hour, `H:MM:SS` at an hour or more. Negative inputs
    /// clamp to zero.
    ///
    /// - Parameter seconds: Elapsed time in whole seconds.
    /// - Returns: A zero-padded timecode string (e.g. `"0:05"`, `"12:30"`,
    ///   `"1:01:01"`).
    public static func timecode(seconds: Int) -> String {
        let total = max(0, seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
