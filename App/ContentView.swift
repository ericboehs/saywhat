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
///
/// On speakers the remote echoes back into the mic, so ``EchoSuppressor`` drops
/// mic speech that repeats recent remote speech — the same stopgap the final-pass
/// merge uses — so the remote doesn't show up as the user. See DESIGN.md §5.
@MainActor
@Observable
final class CaptureModel {
    private(set) var isRecording = false

    private(set) var micLevel: Float = 0
    private(set) var systemLevel: Float = 0

    /// The live transcript: mic and system each transcribed on their own track,
    /// attributed by channel (mic = you, system = remote).
    private(set) var transcript = LiveTranscript()

    /// The authoritative transcript from the final pass, shown once a recording
    /// has been re-transcribed and diarized at meeting end (nil until then).
    private(set) var finalTranscript: Transcript?
    /// Non-nil while the final pass runs, narrating its current stage.
    private(set) var finalizeStatus: String?
    /// Plays the finished recording's mixed audio so the final transcript can be
    /// followed karaoke-style; set once the final pass produces a transcript.
    private(set) var playback: PlaybackController?

    private(set) var sessionPath: String?
    private(set) var errorMessage: String?

    private let microphone = MicrophoneCapture()
    private let system = SystemAudioCapture()
    private let micTranscriber = AppleSpeechTranscriber(source: .microphone)
    private let systemTranscriber = AppleSpeechTranscriber(source: .system)
    private let diarizer: any Diarizer = SortformerLiveDiarizer()
    private var recording: Task<Void, Never>?

    /// The batch final pass: Parakeet per track + offline pyannote, merged into
    /// the authoritative transcript over the session's saved AAC (DESIGN.md §3).
    /// The persistent voiceprint store lets it name remote speakers ("Eric") the
    /// same way across meetings; a store failure degrades to generic labels.
    private let finalPass = FinalPass(
        diarizer: OfflinePyannoteDiarizer(),
        store: CaptureModel.voiceprintStore(),
        makeTranscriber: { ParakeetTranscriber(source: $0) }
    )

    /// The diarizer's running split of the system track into remote speaker slots;
    /// names each live system segment's remote slot.
    private var remoteSpeakers = SpeakerTimeline()
    /// End of the latest audio seen, for attributing range-less volatile guesses.
    private var latestTime: Duration = .zero

    /// Streams each finalized live segment to `transcript.md` in the session
    /// directory so the meeting can be read (e.g. `tail -f`) as it happens; `nil`
    /// until a recording starts.
    private var transcriptLog: TranscriptLog?

    /// A rolling window of recent finalized remote speech, used to suppress the
    /// remote's echo on the mic track live (you're on speakers) the same way the
    /// final-pass merge does. Pruned to the last few seconds — echo lags its
    /// source by far less than that.
    private var recentRemoteSpeech: [TranscriptSegment] = []
    /// The remote's current in-flight guess, included in the echo check so an echo
    /// is caught even before the remote line finalizes.
    private var remoteVolatile: TranscriptSegment?
    /// How far back ``recentRemoteSpeech`` keeps remote speech for echo matching.
    private static let echoMemory: Duration = .seconds(8)

    func toggle() {
        if isRecording { stop() } else { start() }
    }

    private func start() {
        isRecording = true
        micLevel = 0
        systemLevel = 0
        transcript = LiveTranscript()
        finalTranscript = nil
        finalizeStatus = nil
        playback?.pause()
        playback = nil
        remoteSpeakers = SpeakerTimeline()
        recentRemoteSpeech = []
        remoteVolatile = nil
        latestTime = .zero
        transcriptLog = nil
        errorMessage = nil

        let session = RecordingSession(directory: Self.newSessionDirectory())
        sessionPath = session.directory.path

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
            let transcript = try await finalPass.run(session) { phase in
                Task { @MainActor in self.finalizeStatus = Self.describe(phase) }
            }
            finalTranscript = transcript
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

    /// Drain one track's transcriber into the live transcript, attributing each
    /// segment by channel. Both transcribers update `transcript` on the main
    /// actor, so their interleaved segments never race. Transcription failures
    /// (e.g. denied speech permission) surface as a message and never affect
    /// capture or storage.
    private func transcribe(_ frames: AsyncStream<AudioFrame>, source: CaptureSource) async {
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
    /// dominated its window, remembering finalized remote speech (and the in-flight
    /// guess) so the mic track can suppress its echo.
    private func ingestRemote(_ segment: TranscriptSegment) {
        let slot = remoteSpeakers.dominantSpeaker(in: attributionWindow(for: segment)) ?? 0
        if segment.isFinal {
            remoteVolatile = nil
            recordRemoteSpeech(segment)
            transcript.appendFinal(segment.text, label: .remote(slot), source: .system)
            logFinal(segment, label: .remote(slot))
        } else {
            remoteVolatile = segment
            transcript.setVolatile(segment.text, label: .remote(slot), source: .system)
        }
    }

    /// Add a mic segment as *you* — unless it's the remote echoing through the
    /// speakers back into the mic, which is dropped (clearing any tentative echo
    /// already shown) so the remote's words don't appear as the user's.
    private func ingestMic(_ segment: TranscriptSegment) {
        if isRemoteEcho(segment) {
            transcript.setVolatile("", label: .you, source: .microphone)
        } else if segment.isFinal {
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

    /// Whether a mic segment is an echo of recent or in-flight remote speech.
    private func isRemoteEcho(_ segment: TranscriptSegment) -> Bool {
        let window = attributionWindow(for: segment)
        var remote = recentRemoteSpeech
        if let remoteVolatile {
            // The in-flight remote guess has no settled range; span the window
            // under test so it can overlap and match.
            remote.append(TranscriptSegment(
                source: .system,
                text: remoteVolatile.text,
                range: window,
                isFinal: true
            ))
        }
        return EchoSuppressor(system: remote).isEcho(text: segment.text, range: window)
    }

    /// Remember a finalized remote segment for echo matching, dropping speech
    /// older than ``echoMemory`` so the buffer stays small.
    private func recordRemoteSpeech(_ segment: TranscriptSegment) {
        recentRemoteSpeech.append(segment)
        let cutoff = latestTime - Self.echoMemory
        recentRemoteSpeech.removeAll { $0.end < cutoff }
    }

    /// Keep the latest remote-speaker timeline as the diarizer refines it.
    /// Diarization failures (e.g. model download) surface as a message and never
    /// affect capture, storage, or transcription — the transcript just loses
    /// remote-speaker names and falls back to "Speaker 1".
    private func diarizeRemote(_ frames: AsyncStream<AudioFrame>) async {
        do {
            for await timeline in try await diarizer.diarize(frames) {
                remoteSpeakers = timeline
            }
        } catch {
            errorMessage = "diarize: \(error)"
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

    private func update(_ source: CaptureSource, with frame: AudioFrame) {
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
    private static func smooth(_ current: Float, toward target: Float) -> Float {
        target > current ? target : current * 0.8 + target * 0.2
    }
}

extension CaptureModel {
    /// A timestamped session directory under our bundle-namespaced Application
    /// Support, e.g. `…/Application Support/com.boehs.saywhat/Recordings/session-1750876200`.
    ///
    /// The bundle-id namespace keeps us from writing loose folders into the
    /// shared `~/Library/Application Support`. A sandboxed build does this via
    /// its container, but an unsigned dev build runs unsandboxed against the
    /// real directory, so we namespace explicitly.
    static func newSessionDirectory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let namespace = Bundle.main.bundleIdentifier ?? "SayWhat"
        let stamp = Int(Date().timeIntervalSince1970)
        return base
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
            .appendingPathComponent("session-\(stamp)", isDirectory: true)
    }

    /// Open the persistent voiceprint database under our bundle-namespaced
    /// Application Support (alongside `Recordings/`). Returns `nil` if it can't be
    /// opened — the final pass then falls back to generic `Speaker N` labels
    /// rather than failing. On-device only; nothing here leaves the machine.
    static func voiceprintStore() -> VoiceprintStore? {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let namespace = Bundle.main.bundleIdentifier ?? "SayWhat"
        let directory = base.appendingPathComponent(namespace, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("voiceprints.sqlite").path
        return try? VoiceprintStore(path: path)
    }
}

struct ContentView: View {
    @State private var model = CaptureModel()

    var body: some View {
        VStack(spacing: 16) {
            Text("Say What")
                .font(.largeTitle.bold())
            Text(model.isRecording ? "Recording…" : "Idle")
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 16) {
                TrackRow(
                    title: "Microphone",
                    level: model.micLevel,
                    active: model.isRecording
                )
                TrackRow(
                    title: "System audio",
                    level: model.systemLevel,
                    active: model.isRecording
                )
            }

            Group {
                if let status = model.finalizeStatus {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(status).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let finalTranscript = model.finalTranscript, !model.isRecording {
                    VStack(spacing: 12) {
                        FinalTranscriptView(
                            transcript: finalTranscript,
                            cursor: model.playback.flatMap {
                                finalTranscript.wordCursor(at: $0.currentTime)
                            },
                            onSeek: { model.playback?.seek(to: $0) }
                        )
                        if let playback = model.playback {
                            PlaybackBar(playback: playback)
                        }
                    }
                } else {
                    LiveTranscriptView(
                        transcript: model.transcript,
                        active: model.isRecording
                    )
                }
            }
            .frame(minHeight: 200)

            if let sessionPath = model.sessionPath {
                Text(sessionPath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Button(model.isRecording ? "Stop" : "Record") {
                model.toggle()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(model.isRecording ? .red : .accentColor)
            .disabled(model.finalizeStatus != nil)
        }
        .padding(40)
        .frame(minWidth: 560, minHeight: 540)
    }
}

#Preview {
    ContentView()
}
