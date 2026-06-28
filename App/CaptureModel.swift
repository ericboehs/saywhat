import Foundation
import SayWhatCore
import SwiftUI

/// Drives both capture tracks (``MicrophoneCapture`` + ``SystemAudioCapture``),
/// meters each, and persists each to durable AAC via a per-track
/// ``DurableAACWriter`` in a ``RecordingSession``. Capture and storage stay
/// separate end to end (the core invariant), and so does the live transcript:
/// each track feeds its **own** ``AppleSpeechTranscriber``, never a mix. A single
/// recognizer can't separate two voices talking at once and drops the quieter
/// one; per-track recognizers keep the user's overlapping speech. See DESIGN.md §5.
///
/// Attribution is by channel, the way the final pass does it: the mic track is
/// always *you*, and the system track is the remote — split into speaker slots by
/// a ``Diarizer`` (FluidAudio Sortformer) running on that track, so each remote
/// segment takes the slot that dominated its window. See DESIGN.md §6.
@MainActor
@Observable
final class CaptureModel {
    private(set) var isRecording = false

    private(set) var micLevel: Float = 0
    private(set) var systemLevel: Float = 0

    /// The live transcript: mic and system each transcribed on their own track,
    /// attributed by channel (mic = you, system = remote).
    private(set) var transcript = LiveTranscript()

    // Editable session state — written by the recording lifecycle and by the
    // editing/library extension (``CaptureModel+Editing``), so its setters are
    // module-internal rather than `private(set)`. The live/metering state above
    // stays read-only to the rest of the app.

    /// The authoritative transcript from the final pass, shown once a recording
    /// has been re-transcribed and diarized at meeting end (nil until then).
    var finalTranscript: Transcript?
    /// Remote slot → how the final pass resolved it (matched person or un-named
    /// mint), so naming a slot can bind its exemplar to a person. Empty until the
    /// final pass runs (and when identity resolution was skipped).
    var speakers: [Int: ResolvedSpeaker] = [:]
    /// Utterance id → that segment's own voiceprint, from the final pass. Lets a
    /// single mis-grouped segment be reassigned to (and teach) the right person,
    /// even when its group's exemplar belongs to someone else. Empty until the pass
    /// runs; reloaded with a reopened session.
    var utteranceVoiceprints: [Int: Voiceprint] = [:]
    /// Persists the authoritative transcript beside the current session's audio so
    /// hand-corrected speaker labels survive reopening. Set when the final pass
    /// finishes (or a saved session is reopened); `nil` before then.
    var transcriptStore: TranscriptStore?
    /// Remote slot → the enrolled name the **live** namer recognized mid-meeting,
    /// shown on the live transcript so a known voice reads as "Eric" before the
    /// final pass confirms it. Empty until a voice is matched; reset each start.
    private(set) var liveNames: [Int: String] = [:]
    /// Remote slot → the live namer's latest diagnostics (nearest enrolled voice +
    /// score + accumulated audio), shown only when the Debug overlay is on so the
    /// live identification can be watched as it resolves. Reset each start.
    private(set) var liveDebug: [Int: LiveSpeakerNamer.SlotDiagnostics] = [:]
    /// The enrolled voiceprint directory, loaded on demand for the debug inspector
    /// (reveals e.g. duplicate "Zwag" people). Empty until ``loadVoiceprintDirectory()``.
    var voiceprintDirectory: [EnrolledPerson] = []
    /// Non-nil while the final pass runs, narrating its current stage.
    var finalizeStatus: String?
    /// Plays the finished recording's mixed audio so the final transcript can be
    /// followed karaoke-style; set once the final pass produces a transcript.
    var playback: PlaybackController?

    /// Past recordings for the history sidebar, newest first. Refreshed on launch
    /// and whenever a recording finalizes.
    var sessions: [RecordedSession] = []
    /// The id of the session whose transcript is on screen — the just-finished
    /// recording's, or a past one reopened from the sidebar; `nil` before any.
    var selectedSessionID: String?

    var sessionPath: String?
    var errorMessage: String?

    private let microphone = MicrophoneCapture()
    private let system = SystemAudioCapture()
    private let micTranscriber = AppleSpeechTranscriber(source: .microphone)
    private let systemTranscriber = AppleSpeechTranscriber(source: .system)
    private let diarizer: any Diarizer = SortformerLiveDiarizer()
    private var recording: Task<Void, Never>?

    /// Hybrid diarization for the final pass: turns from Sortformer (it splits the
    /// remote speakers cleanly where offline pyannote glues them together) and
    /// voiceprints from pyannote (DESIGN.md §3, §6). Held once so its models stay
    /// loaded across recordings; the pass itself is rebuilt per run to pick up the
    /// current matching fuzziness.
    private let finalDiarizer: any Diarizer = HybridDiarizer(
        turns: SortformerLiveDiarizer(),
        embeddings: OfflinePyannoteDiarizer()
    )

    /// The persistent voiceprint directory: lets the final pass name remote
    /// speakers ("Eric") the same way across meetings, and where a rename is
    /// written back. A store failure degrades to generic labels. Read by the
    /// editing extension, so module-internal rather than private.
    let voiceprintStore = CaptureModel.voiceprintStore()

    /// The shared `wespeaker_v2` identity embedder — the one space both the live
    /// namer and the final pass recognize voices in. Held once so its CoreML model
    /// loads a single time and stays warm across the meeting and the final pass.
    private let speakerEmbedder = WeSpeakerEmbedder()

    /// Names remote speakers live by matching their voice to the store; rebuilt
    /// each recording so it starts with empty buffers and the current fuzziness.
    /// `nil` between recordings.
    private var liveNamer: LiveSpeakerNamer?

    /// The batch final pass over the session's saved AAC — Parakeet per track,
    /// hybrid diarization, merged into the authoritative transcript. Rebuilt each
    /// run so the speaker matcher reflects the user's current fuzziness setting.
    private func makeFinalPass() -> FinalPass {
        FinalPass(
            diarizer: finalDiarizer,
            store: voiceprintStore,
            resegmenter: SpeakerResegmenter(
                resolver: SpeakerResolver(matcher: VoiceprintMatcher(threshold: AppSettings
                        .matchThreshold))
            ),
            embedder: speakerEmbedder,
            makeTranscriber: { ParakeetTranscriber(source: $0) }
        )
    }

    /// The diarizer's running split of the system track into remote speaker slots;
    /// names each live system segment's remote slot.
    private var remoteSpeakers = SpeakerTimeline()
    /// End of the latest audio seen, for attributing range-less volatile guesses.
    private var latestTime: Duration = .zero

    /// Streams each finalized live segment to `transcript.md` in the session
    /// directory so the meeting can be read (e.g. `tail -f`) as it happens; `nil`
    /// until a recording starts.
    private var transcriptLog: TranscriptLog?

    func toggle() {
        if isRecording { stop() } else { start() }
    }

    /// Clear last meeting's state and build a fresh live namer (empty buffers, the
    /// current matching fuzziness) so a new recording starts clean.
    private func resetForRecording() {
        isRecording = true
        micLevel = 0
        systemLevel = 0
        transcript = LiveTranscript()
        finalTranscript = nil
        speakers = [:]
        liveNames = [:]
        liveDebug = [:]
        liveNamer = LiveSpeakerNamer(
            embedder: speakerEmbedder,
            store: voiceprintStore,
            matcher: VoiceprintMatcher(threshold: AppSettings.matchThreshold)
        )
        finalizeStatus = nil
        playback?.pause()
        playback = nil
        // The live recording isn't a saved session yet; clear any reopened one so
        // the detail pane follows the recording until it finalizes.
        selectedSessionID = nil
        utteranceVoiceprints = [:]
        transcriptStore = nil
        remoteSpeakers = SpeakerTimeline()
        latestTime = .zero
        transcriptLog = nil
        errorMessage = nil
    }

    private func start() {
        resetForRecording()

        let session = RecordingSession(directory: Self.newSessionDirectory())
        sessionPath = session.directory.path

        // Surface the recording in the sidebar the moment it starts, selected, so it
        // doesn't pop in only at the end. SessionLibrary won't list it yet (no audio
        // on disk), so prepend a live entry; refreshSessions() replaces it with the
        // finalized one (same id) once the pass writes transcript.json.
        let id = session.directory.lastPathComponent
        selectedSessionID = id
        sessions.insert(
            RecordedSession(
                id: id,
                directory: session.directory,
                date: Date(),
                hasTranscript: false
            ),
            at: 0
        )

        recording = Task { [microphone, system] in
            do {
                try session.createDirectory()
                // The directory now exists; start streaming finalized lines to it.
                transcriptLog = TranscriptLog(directory: session.directory)
                let micWriter = try session.writer(for: .microphone)
                let systemWriter = try session.writer(for: .system)

                // Each track feeds its own live transcriber on a private stream —
                // claim both before the pumps start feeding them. A third stream
                // fans the system track to the diarizer (remote speaker splitting
                // runs on the system track only — §6).
                let (micAudio, micFeed) = AsyncStream<AudioFrame>.makeStream()
                let (systemAudio, systemFeed) = AsyncStream<AudioFrame>.makeStream()
                let (remoteAudio, remoteFeed) = AsyncStream<AudioFrame>.makeStream()

                // Transcribe each track and diarize the system track while both
                // tracks are captured, metered, stored, and fanned to their
                // recognizers. Each loop ends when its source finishes.
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await self.transcribe(micAudio, source: .microphone) }
                    group.addTask { await self.transcribe(systemAudio, source: .system) }
                    group.addTask { await self.diarizeRemote(remoteAudio) }
                    group.addTask { await self.nameSpeakersLive() }
                    group.addTask {
                        await self.pump(
                            microphone,
                            into: micWriter,
                            source: .microphone,
                            transcriberFeed: micFeed,
                            diarizerFeed: nil
                        )
                    }
                    group.addTask {
                        await self.pump(
                            system,
                            into: systemWriter,
                            source: .system,
                            transcriberFeed: systemFeed,
                            diarizerFeed: remoteFeed
                        )
                    }
                }

                // Streams drained — close both segments and mark the session
                // cleanly finalized so recovery knows it wasn't interrupted.
                try await micWriter.finalize()
                try await systemWriter.finalize()
                try session.markFinalized()

                // Mix both tracks into one shareable recording.m4a. A convenience
                // derived from the durable segments, so a failure here is logged
                // and shrugged off rather than allowed to disturb the recording.
                _ = try? await RecordingExporter.exportCombined(session)

                // Capture is fully durable and closed; now re-transcribe and
                // diarize the saved audio into the authoritative transcript.
                await self.runFinalPass(session)
            } catch {
                self.errorMessage = String(describing: error)
            }
        }
    }

    /// Run the batch final pass over a finalized session and surface the
    /// authoritative transcript. Failures (e.g. a model download) surface as a
    /// message and never affect the saved recording, which is already durable.
    private func runFinalPass(_ session: RecordingSession) async {
        finalizeStatus = Self.describe(.transcribing(.microphone))
        do {
            let outcome = try await makeFinalPass().run(session) { phase in
                Task { @MainActor in self.finalizeStatus = Self.describe(phase) }
            }
            finalTranscript = outcome.transcript
            speakers = outcome.speakers
            utteranceVoiceprints = outcome.utteranceVoiceprints
            // Persist the authoritative transcript beside its audio so later edits
            // (and reopening the session) start from this, not a fresh re-run.
            transcriptStore = TranscriptStore(directory: session.directory)
            persist()
            // Surface the just-finished recording in the sidebar and select it.
            selectedSessionID = session.directory.lastPathComponent
            refreshSessions()
            // Make the saved audio playable so the transcript can be followed
            // along; a failure here just leaves playback unavailable.
            let controller = PlaybackController()
            await controller.load(session: session)
            if controller.isReady { playback = controller }
        } catch let timeout as TimeoutError {
            errorMessage = "Finalize timed out at \(timeout.label). The recording is saved — try again."
        } catch {
            errorMessage = "finalize: \(error)"
        }
        finalizeStatus = nil
    }

    /// Whether the open recording can be reprocessed: one is selected and we're
    /// idle (not recording, not already mid-finalize).
    var canReprocess: Bool {
        selectedSessionID != nil && !isRecording && finalizeStatus == nil
    }

    /// Re-run the final pass over the selected recording's saved audio, replacing
    /// its transcript — for when a model improved, or after enrolling/merging
    /// voiceprints so identities re-resolve cleanly. Because naming is persisted as
    /// voiceprints, prior names carry into the new transcript; manual per-segment
    /// reassignments that weren't voiceprint-backed are not preserved. The durable
    /// audio is never touched. A no-op unless ``canReprocess``.
    func reprocessSelected() {
        guard canReprocess, let id = selectedSessionID,
              let session = sessions.first(where: { $0.id == id }) else { return }
        Task { await runFinalPass(RecordingSession(directory: session.directory)) }
    }

    /// A reader-facing description of a final-pass stage.
    private static func describe(_ phase: FinalPass.Phase) -> String {
        switch phase {
        case .transcribing(.microphone): "Transcribing your audio…"
        case .transcribing(.system): "Transcribing the meeting…"
        case .diarizing: "Identifying speakers…"
        case .merging: "Assembling transcript…"
        }
    }

    private func stop() {
        isRecording = false
        micLevel = 0
        systemLevel = 0
        // Finishing each capture stream lets the pumps drain and the recording
        // task finalize on its own; never cancel it (that would drop the tail).
        Task { [microphone, system] in
            await microphone.stop()
            await system.stop()
        }
    }

    /// Meter, persist, and fan out one track's frames until its stream finishes.
    /// Each frame goes to the durable writer (storage), this track's live
    /// transcriber, and — for the system track — the diarizer feed (remote-speaker
    /// splitting). A write failure surfaces its message without tearing down
    /// capture or the other track. On end, both downstream streams are closed.
    private func pump(
        _ capture: any AudioCapture,
        into writer: DurableAACWriter,
        source: CaptureSource,
        transcriberFeed: AsyncStream<AudioFrame>.Continuation,
        diarizerFeed: AsyncStream<AudioFrame>.Continuation?
    ) async {
        do {
            let frames = try await capture.start()
            for await frame in frames {
                update(source, with: frame)
                transcriberFeed.yield(frame)
                diarizerFeed?.yield(frame)
                // Feed the live namer the same system audio the diarizer sees, so
                // it can match each remote slot's voice to an enrolled name.
                if source == .system { await liveNamer?.ingest(frame) }
                do {
                    try await writer.append(frame)
                } catch {
                    // A write failure must not take down capture (durability
                    // invariant) — surface it and keep metering.
                    errorMessage = "write \(source.rawValue): \(error)"
                }
            }
        } catch {
            errorMessage = "\(source.rawValue): \(error)"
        }
        transcriberFeed.finish()
        diarizerFeed?.finish()
    }
}

/// The live-pipeline half of ``CaptureModel``: draining each track's transcriber
/// into the on-screen transcript, keeping the remote-speaker timeline, naming
/// remote voices mid-meeting, and metering. Split into an extension so the model's
/// main declaration stays focused on the capture/recording lifecycle.
extension CaptureModel {
    /// Drain one track's transcriber into the live transcript, attributing each
    /// segment by channel. Both transcribers update `transcript` on the main
    /// actor, so their interleaved segments never race. Transcription failures
    /// (e.g. denied speech permission) surface as a message and never affect
    /// capture or storage.
    func transcribe(_ frames: AsyncStream<AudioFrame>, source: CaptureSource) async {
        let transcriber = source == .microphone ? micTranscriber : systemTranscriber
        do {
            for try await segment in try await transcriber.transcribe(frames) {
                switch source {
                case .system: ingestRemote(segment)
                case .microphone: ingestMic(segment)
                }
            }
        } catch {
            errorMessage = "transcribe \(source.rawValue): \(error)"
        }
    }

    /// Add a remote (system-track) segment, tagged with the slot the diarizer says
    /// dominated its window.
    private func ingestRemote(_ segment: TranscriptSegment) {
        let slot = remoteSpeakers.dominantSpeaker(in: attributionWindow(for: segment)) ?? 0
        if segment.isFinal {
            transcript.appendFinal(segment.text, label: .remote(slot), source: .system)
            logFinal(segment, label: .remote(slot))
        } else {
            transcript.setVolatile(segment.text, label: .remote(slot), source: .system)
        }
    }

    /// Add a mic segment as *you*.
    private func ingestMic(_ segment: TranscriptSegment) {
        if segment.isFinal {
            transcript.appendFinal(segment.text, label: .you, source: .microphone)
            logFinal(segment, label: .you)
        } else {
            transcript.setVolatile(segment.text, label: .you, source: .microphone)
        }
    }

    /// Append a finalized live segment to the session's `transcript.md` so it can
    /// be read while the meeting is still going. Best-effort: a log-write failure
    /// must never disturb capture, storage, or the on-screen transcript.
    private func logFinal(_ segment: TranscriptSegment, label: SpeakerLabel) {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let timecode = SayWhat.timecode(seconds: Int(segment.start.seconds))
        try? transcriptLog?.append(timecode: timecode, speaker: label.displayName, text: text)
    }

    /// Keep the latest remote-speaker timeline as the diarizer refines it, and
    /// hand it to the live namer so it can attribute voices. Diarization failures
    /// (e.g. model download) surface as a message and never affect capture,
    /// storage, or transcription — the transcript just loses remote-speaker names
    /// and falls back to "Speaker 1".
    func diarizeRemote(_ frames: AsyncStream<AudioFrame>) async {
        do {
            for await timeline in try await diarizer.diarize(frames) {
                remoteSpeakers = timeline
                await liveNamer?.update(timeline)
            }
        } catch {
            errorMessage = "diarize: \(error)"
        }
    }

    /// Periodically ask the live namer to match any unnamed remote slot to an
    /// enrolled voice, publishing the result for the transcript. Throttled — each
    /// unresolved slot costs an embedding inference — and self-terminating when
    /// recording stops so it never outlives the meeting it names.
    func nameSpeakersLive() async {
        while isRecording {
            try? await Task.sleep(for: .seconds(2))
            guard let namer = liveNamer else { continue }
            let names = await namer.resolve()
            if names != liveNames { liveNames = names }
            let debug = await namer.debug()
            if debug != liveDebug { liveDebug = debug }
        }
    }

    /// The window used to attribute a segment. Final segments carry a real time
    /// range; a range-less volatile guess is attributed by the last second of
    /// audio (who is talking right now).
    private func attributionWindow(for segment: TranscriptSegment) -> Range<Duration> {
        if segment.end > segment.start { return segment.range }
        let start = latestTime > .seconds(1) ? latestTime - .seconds(1) : .zero
        return start ..< Swift.max(latestTime, start)
    }

    /// Update one track's meter and advance the latest-seen clock.
    func update(_ source: CaptureSource, with frame: AudioFrame) {
        switch source {
        case .microphone:
            micLevel = Self.smooth(micLevel, toward: frame.meterLevel())
        case .system:
            systemLevel = Self.smooth(systemLevel, toward: frame.meterLevel())
        }
        latestTime = Swift.max(latestTime, frame.startOffset + frame.duration)
    }

    /// Attack fast, release slow — a meter that snaps up to peaks but eases back
    /// so it reads instead of flickering.
    static func smooth(_ current: Float, toward target: Float) -> Float {
        target > current ? target : current * 0.8 + target * 0.2
    }
}
