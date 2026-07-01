import AVFoundation
import SayWhatCore
import SwiftUI

/// Plays a finished recording's two AAC tracks together so the final transcript
/// can be followed karaoke-style.
///
/// Both tracks are kept separate on disk (the core invariant), but for *playback*
/// they're mixed: each track's rotating segments are concatenated into one
/// composition audio track, the two laid over each other from session time 0, and
/// an `AVPlayer` renders the sum. The published ``currentTime`` drives word
/// highlighting via ``Transcript/wordCursor(at:)`` — nothing here touches the
/// transcript itself. App-side and AVFoundation-backed, so it's exercised by hand,
/// not unit tests (QUALITY.md §6).
@MainActor
@Observable
final class PlaybackController {
    /// Whether audio is currently playing.
    private(set) var isPlaying = false
    /// The playhead position on the session timeline.
    private(set) var currentTime: Duration = .zero
    /// The recording's overall length.
    private(set) var duration: Duration = .zero
    /// `true` once a composition with audio has loaded and is playable.
    private(set) var isReady = false

    private let player = AVPlayer()

    init() {
        // The player solely owns this observer block (self is weak), so it's
        // released when the player is — no manual teardown needed.
        let interval = CMTime(seconds: 0.03, preferredTimescale: 600)
        player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
    }

    /// Build the mixed composition from a finalized session's saved audio. Both
    /// tracks' segments are concatenated in order and overlaid from time 0; a track
    /// with no segments is simply absent. Safe to call once per finished recording.
    func load(session: RecordingSession) async {
        let composition = await RecordingMix.composition(for: session)

        player.replaceCurrentItem(with: AVPlayerItem(asset: composition))
        duration = .seconds(composition.duration.seconds)
        isReady = composition.duration.seconds > 0
    }

    /// Load a single audio file directly, so an import source can be played before
    /// it's decoded into the session's rotating segments. The source shares the
    /// session's 0-based timeline, so the playhead still lines up with the staged
    /// transcript; ``load(session:)`` later swaps in the finalized mix.
    func load(url: URL) async {
        let asset = AVURLAsset(url: url)
        let length = await (try? asset.load(.duration)) ?? .zero
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        duration = .seconds(length.seconds)
        isReady = length.seconds > 0
    }

    /// Advance the published playhead, and stop/rewind once it reaches the end so
    /// the play button replays from the top (no separate end notification needed).
    private func tick(_ time: CMTime) {
        guard time.seconds.isFinite else { return }
        currentTime = .seconds(time.seconds)
        if isPlaying, duration > .zero, currentTime >= duration {
            finish()
        }
    }

    func toggle() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        guard isReady else { return }
        // Replaying after the end: rewind first.
        if currentTime >= duration { seek(to: .zero) }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    /// Move the playhead, clamped to the recording, e.g. from the scrubber.
    func seek(to time: Duration) {
        let clamped = min(max(time, .zero), duration)
        player.seek(
            to: CMTime(seconds: clamped.seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        currentTime = clamped
    }

    /// Reached the end: stop and rewind so the play button replays from the top.
    private func finish() {
        isPlaying = false
        seek(to: .zero)
    }
}

/// Transport for a finished recording: play/pause, a scrubber, and timecodes.
struct PlaybackBar: View {
    /// Injected and observed (not `@State`): the model swaps this controller when
    /// the import source gives way to the finalized session mix, and the transport
    /// must follow the swap — owning it in `@State` would pin the bar to the stale
    /// source controller, so the playhead keeps moving while the highlight (which
    /// reads `model.playback`) sits on the new one. `@Observable` makes a plain
    /// `let` track both the swap and the controller's own published changes.
    let playback: PlaybackController

    var body: some View {
        HStack(spacing: 12) {
            Button {
                playback.toggle()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.space, modifiers: [])

            Text(Self.timecode(playback.currentTime))
                .monospacedDigit()
                .font(.caption)
                .foregroundStyle(.secondary)

            Slider(
                value: Binding(
                    get: { playback.currentTime.seconds },
                    set: { playback.seek(to: .seconds($0)) }
                ),
                in: 0 ... max(playback.duration.seconds, 0.1)
            )

            Text(Self.timecode(playback.duration))
                .monospacedDigit()
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private static func timecode(_ time: Duration) -> String {
        SayWhat.timecode(seconds: Int(time.seconds))
    }
}

extension Duration {
    /// This duration as a floating-point number of seconds, for the AVFoundation
    /// and SwiftUI APIs that speak `Double`/`TimeInterval`.
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
