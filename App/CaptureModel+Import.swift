import Foundation
import SayWhatCore

/// Importing an external recording into the history library: the testing seam that
/// lets the final pass run over audio captured elsewhere (e.g. an earl-scribe
/// meeting) without recording a live call. Split into its own file so the model's
/// main declaration stays focused on the live capture/recording lifecycle.
extension CaptureModel {
    /// Whether a recording can be imported right now: we're idle (not recording,
    /// not already mid-finalize). Like ``canReprocess`` without the selection
    /// requirement, since an import creates its own session.
    var canImport: Bool {
        !isRecording && finalizeStatus == nil
    }

    /// Import an external audio file (e.g. an earl-scribe meeting) as a new session
    /// and immediately run the final pass over it, so the pipeline can be tried on
    /// real audio without recording a live call. The mixed file becomes the system
    /// track (every voice a remote speaker to split and name); the mic track is
    /// left empty. A decode failure surfaces and leaves no half-imported session
    /// selected. A no-op unless ``canImport``.
    func importRecording(from sourceURL: URL) {
        guard canImport else { return }
        let session = RecordingSession(directory: Self.newSessionDirectory())
        Task {
            finalizeStatus = "Importing \(sourceURL.lastPathComponent)…"
            finalizeProgress = nil
            // Let the source file play right away, before it's even decoded — the
            // meeting is listenable while the pass runs.
            await prepareSourcePlayback(from: sourceURL)
            do {
                try await RecordingImporter()(sourceURL, into: session) { fraction in
                    Task { @MainActor in self.setImportProgress(fraction) }
                }
            } catch {
                errorMessage = "import: \(error)"
                finalizeStatus = nil
                finalizeProgress = nil
                playback = nil
                return
            }
            await runFinalPass(session)
        }
    }

    /// Make the import source file playable immediately — before it's decoded into
    /// the session — so the meeting can be listened to while it imports. The source
    /// shares the session's 0-based timeline, so the playhead lines up with the
    /// staged transcript; ``loadSessionPlayback(for:)`` later swaps in the saved mix.
    func prepareSourcePlayback(from url: URL) async {
        let controller = PlaybackController()
        await controller.load(url: url)
        if controller.isReady { playback = controller }
    }

    /// Swap the finalized session mix in for playback once the pass completes,
    /// carrying any in-progress import playhead (and resume state) so listening
    /// stays continuous as the source file gives way to the saved tracks.
    func loadSessionPlayback(for session: RecordingSession) async {
        let controller = PlaybackController()
        await controller.load(session: session)
        guard controller.isReady else { return }
        if let previous = playback {
            let wasPlaying = previous.isPlaying
            previous.pause()
            controller.seek(to: previous.currentTime)
            if wasPlaying { controller.play() }
        }
        playback = controller
    }

    /// Set the bar during an import — which runs before the final pass and isn't a
    /// ``FinalPass/Phase``. Clearing the phase means the first real phase tick that
    /// follows relabels the status and resets the bar.
    func setImportProgress(_ fraction: Double?) {
        finalizePhase = nil
        finalizeProgress = fraction
    }

    /// Apply a staged transcript from the final pass — text, then separated speakers —
    /// so it shows early and refines in place. Guarded by ``finalizeStage`` so an
    /// out-of-order main-actor hop can't drop back to an older stage; the named final
    /// result claims `.max` and wins. Partials carry no speakers/voiceprints yet.
    func applyPartial(_ partial: FinalPass.Partial) {
        guard partial.stage > finalizeStage else { return }
        finalizeStage = partial.stage
        finalTranscript = partial.outcome.transcript
        speakers = partial.outcome.speakers
        utteranceVoiceprints = partial.outcome.utteranceVoiceprints
    }

    /// Fold one final-pass progress tick into the UI state. A new phase relabels the
    /// status and clears the bar; within a phase the bar only ever moves forward, so
    /// out-of-order ticks (each arrives on its own main-actor hop) can't rewind it.
    func advanceFinalize(_ progress: FinalPass.Progress) {
        if finalizePhase != progress.phase {
            finalizePhase = progress.phase
            finalizeStatus = CaptureModel.describe(progress.phase)
            finalizeProgress = nil
        }
        if let fraction = progress.fraction {
            finalizeProgress = max(finalizeProgress ?? 0, fraction)
        }
    }
}
