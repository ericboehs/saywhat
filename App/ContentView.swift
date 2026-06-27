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

    private(set) var micFrameCount = 0
    private(set) var micSampleCount = 0
    private(set) var micLevel: Float = 0

    private(set) var systemFrameCount = 0
    private(set) var systemSampleCount = 0
    private(set) var systemLevel: Float = 0

    /// The live transcript: mic and system each transcribed on their own track,
    /// attributed by channel (mic = you, system = remote).
    private(set) var transcript = LiveTranscript()

    /// The authoritative transcript from the final pass, shown once a recording
    /// has been re-transcribed and diarized at meeting end (nil until then).
    private(set) var finalTranscript: Transcript?
    /// Non-nil while the final pass runs, narrating its current stage.
    private(set) var finalizeStatus: String?

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

    func toggle() {
        if isRecording { stop() } else { start() }
    }

    private func start() {
        isRecording = true
        micFrameCount = 0
        micSampleCount = 0
        micLevel = 0
        systemFrameCount = 0
        systemSampleCount = 0
        systemLevel = 0
        transcript = LiveTranscript()
        finalTranscript = nil
        finalizeStatus = nil
        remoteSpeakers = SpeakerTimeline()
        latestTime = .zero
        errorMessage = nil

        let session = RecordingSession(directory: Self.newSessionDirectory())
        sessionPath = session.directory.path

        recording = Task { [microphone, system] in
            do {
                try session.createDirectory()
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
                let label = speakerLabel(for: source, segment: segment)
                if segment.isFinal {
                    transcript.appendFinal(segment.text, label: label, source: source)
                } else {
                    transcript.setVolatile(segment.text, label: label, source: source)
                }
            }
        } catch {
            errorMessage = "transcribe \(source.rawValue): \(error)"
        }
    }

    /// Attribute a segment by channel: the mic is always *you*; a system segment
    /// takes the remote slot the diarizer says dominated its window (slot 0 until
    /// diarization has split anyone out).
    private func speakerLabel(
        for source: CaptureSource,
        segment: TranscriptSegment
    ) -> SpeakerLabel {
        switch source {
        case .microphone:
            return .you
        case .system:
            let slot = remoteSpeakers.dominantSpeaker(in: attributionWindow(for: segment)) ?? 0
            return .remote(slot)
        }
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
            micFrameCount += 1
            micSampleCount += frame.samples.count
            micLevel = Self.smooth(micLevel, toward: frame.meterLevel())
        case .system:
            systemFrameCount += 1
            systemSampleCount += frame.samples.count
            systemLevel = Self.smooth(systemLevel, toward: frame.meterLevel())
        }
        latestTime = Swift.max(latestTime, frame.startOffset + frame.duration)
    }

    /// A timestamped session directory under our bundle-namespaced Application
    /// Support, e.g. `…/Application Support/com.boehs.saywhat/Recordings/session-1750876200`.
    ///
    /// The bundle-id namespace keeps us from writing loose folders into the
    /// shared `~/Library/Application Support`. A sandboxed build does this via
    /// its container, but an unsigned dev build runs unsandboxed against the
    /// real directory, so we namespace explicitly.
    private static func newSessionDirectory() -> URL {
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
    private static func voiceprintStore() -> VoiceprintStore? {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let namespace = Bundle.main.bundleIdentifier ?? "SayWhat"
        let directory = base.appendingPathComponent(namespace, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("voiceprints.sqlite").path
        return try? VoiceprintStore(path: path)
    }

    /// Attack fast, release slow — a meter that snaps up to peaks but eases back
    /// so it reads instead of flickering.
    private static func smooth(_ current: Float, toward target: Float) -> Float {
        target > current ? target : current * 0.8 + target * 0.2
    }
}

/// A horizontal input-level meter driven by a `0...1` level, green→red as it
/// approaches clipping.
struct LevelMeter: View {
    var level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(level < 0.85 ? Color.green : Color.red)
                    .frame(width: geometry.size.width * CGFloat(min(max(level, 0), 1)))
            }
        }
        .frame(height: 8)
        .animation(.linear(duration: 0.05), value: level)
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(min(max(level, 0), 1) * 100)) percent")
    }
}

/// One track's label, meter, and frame/sample counters.
struct TrackRow: View {
    var title: String
    var level: Float
    var frames: Int
    var samples: Int
    var active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            LevelMeter(level: level)
                .opacity(active ? 1 : 0.35)
            Text("\(frames) frames · \(samples) samples")
                .monospacedDigit()
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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

            TrackRow(
                title: "Microphone",
                level: model.micLevel,
                frames: model.micFrameCount,
                samples: model.micSampleCount,
                active: model.isRecording
            )
            TrackRow(
                title: "System audio",
                level: model.systemLevel,
                frames: model.systemFrameCount,
                samples: model.systemSampleCount,
                active: model.isRecording
            )

            Group {
                if let status = model.finalizeStatus {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(status).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let finalTranscript = model.finalTranscript, !model.isRecording {
                    FinalTranscriptView(transcript: finalTranscript)
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
