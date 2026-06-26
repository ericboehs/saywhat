import Foundation
import SayWhatCore
import SwiftUI

/// Drives both capture tracks (``MicrophoneCapture`` + ``SystemAudioCapture``),
/// meters each, and persists each to durable AAC via a per-track
/// ``DurableAACWriter`` in a ``RecordingSession``. Capture and storage stay
/// separate end to end (the core invariant). For the *live transcript only*,
/// both tracks are summed through an ``AudioMixer`` into one
/// ``AppleSpeechTranscriber`` — so the speaker echo transcribes once, with no
/// dedupe and nothing retracted on screen. See DESIGN.md §5.
///
/// Each transcript segment is attributed to a speaker: the mic channel is *you*,
/// and a ``Diarizer`` (FluidAudio Sortformer) runs on the **system track** to
/// split the remote speakers. ``SpeakerLabeler`` combines the two — mic-vs-system
/// energy over the segment's window decides you-vs-remote, then the diarizer's
/// timeline names the remote slot. See DESIGN.md §6.
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

    /// The live transcript of the mixed mic+system audio, attributed by speaker.
    private(set) var transcript = LiveTranscript()

    private(set) var sessionPath: String?
    private(set) var errorMessage: String?

    private let microphone = MicrophoneCapture()
    private let system = SystemAudioCapture()
    private let transcriber = AppleSpeechTranscriber(source: .microphone)
    private let diarizer: any Diarizer = SortformerLiveDiarizer()
    private var recording: Task<Void, Never>?

    // Per-segment speaker attribution. Energy envelopes of both tracks decide
    // you-vs-remote; the diarizer timeline names the remote speaker.
    private let labeler = SpeakerLabeler()
    private var micEnergy = EnergyTrack()
    private var systemEnergy = EnergyTrack()
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
        micEnergy = EnergyTrack()
        systemEnergy = EnergyTrack()
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

                // One mixer sums both tracks for the single live transcriber;
                // claim its output stream before the pumps start feeding it. A
                // separate stream fans the system track to the diarizer (remote
                // speaker splitting runs on the system track only — §6).
                let mixer = AudioMixer()
                let mixed = await mixer.output()
                let (remoteAudio, remoteFeed) = AsyncStream<AudioFrame>.makeStream()

                // Transcribe the mix and diarize the system track while both
                // tracks are captured, metered, stored, mixed, and (system only)
                // fed to the diarizer. Each loop ends when its source finishes.
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await self.transcribeMixed(mixed) }
                    group.addTask { await self.diarizeRemote(remoteAudio) }
                    group.addTask {
                        await self.pump(
                            microphone,
                            into: micWriter,
                            source: .microphone,
                            mixer: mixer,
                            diarizerFeed: nil
                        )
                    }
                    group.addTask {
                        await self.pump(
                            system,
                            into: systemWriter,
                            source: .system,
                            mixer: mixer,
                            diarizerFeed: remoteFeed
                        )
                    }
                }

                // Streams drained — close both segments and mark the session
                // cleanly finalized so recovery knows it wasn't interrupted.
                try await micWriter.finalize()
                try await systemWriter.finalize()
                try session.markFinalized()
            } catch {
                self.errorMessage = String(describing: error)
            }
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

    /// Meter, persist, and mix one track's frames until its stream finishes.
    /// Each frame fans out to the durable writer (storage), the shared
    /// ``AudioMixer`` (live transcript), and — for the system track — the
    /// diarizer feed (remote-speaker splitting). A write failure surfaces its
    /// message without tearing down capture or the other track. On end, the
    /// track is marked finished on the mixer and the diarizer feed is closed.
    private func pump(
        _ capture: any AudioCapture,
        into writer: DurableAACWriter,
        source: CaptureSource,
        mixer: AudioMixer,
        diarizerFeed: AsyncStream<AudioFrame>.Continuation?
    ) async {
        do {
            let frames = try await capture.start()
            for await frame in frames {
                update(source, with: frame)
                await mixer.feed(source, frame.samples)
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
        diarizerFeed?.finish()
        await mixer.finish(source)
    }

    /// Drain the mixed transcriber's segments into the live transcript,
    /// attributing each to a speaker. Transcription failures (e.g. denied speech
    /// permission) surface as a message and never affect capture or storage.
    private func transcribeMixed(_ frames: AsyncStream<AudioFrame>) async {
        do {
            for try await segment in try await transcriber.transcribe(frames) {
                let label = labeler.label(
                    segment: attributionWindow(for: segment),
                    mic: micEnergy,
                    system: systemEnergy,
                    remoteSpeakers: remoteSpeakers
                )
                if segment.isFinal {
                    transcript.appendFinal(segment.text, label: label)
                } else {
                    transcript.setVolatile(segment.text, label: label)
                }
            }
        } catch {
            errorMessage = "transcribe: \(error)"
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
            micEnergy.record(frame)
        case .system:
            systemFrameCount += 1
            systemSampleCount += frame.samples.count
            systemLevel = Self.smooth(systemLevel, toward: frame.meterLevel())
            systemEnergy.record(frame)
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

/// The live transcript of the mixed audio, grouped into speaker turns. Committed
/// (final) text lands in ``Block``s — consecutive finals from the same speaker
/// merge into one paragraph — and the in-flight volatile guess trails as its own
/// tentative block. One recognizer drives it, so text only ever appends; nothing
/// already shown is retracted.
struct LiveTranscript: Equatable {
    /// One speaker's contiguous run of committed text.
    struct Block: Equatable, Identifiable {
        let id = UUID()
        var label: SpeakerLabel
        var text: String
    }

    private(set) var blocks: [Block] = []
    /// The latest in-flight volatile guess (empty between utterances).
    private(set) var volatile = ""
    /// Best-guess speaker for the volatile tail.
    private(set) var volatileLabel: SpeakerLabel = .you

    var isEmpty: Bool {
        blocks.isEmpty && volatile.isEmpty
    }

    /// Commit a final segment: extend the last block if the same speaker still
    /// holds the floor, otherwise start a new one. Clears the volatile tail.
    mutating func appendFinal(_ text: String, label: SpeakerLabel) {
        volatile = ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if var last = blocks.last, last.label == label {
            last.text += " " + trimmed
            blocks[blocks.count - 1] = last
        } else {
            blocks.append(Block(label: label, text: trimmed))
        }
    }

    /// Replace the in-flight guess and its speaker.
    mutating func setVolatile(_ text: String, label: SpeakerLabel) {
        volatile = text.trimmingCharacters(in: .whitespacesAndNewlines)
        volatileLabel = label
    }
}

extension SpeakerLabel {
    /// Display name for the live view. Remote slots are 0-based; show them 1-based.
    var displayName: String {
        switch self {
        case .you: "You"
        case let .remote(slot): "Speaker \(slot + 1)"
        }
    }

    /// A stable accent color per speaker so turns are scannable at a glance.
    var tint: Color {
        switch self {
        case .you:
            return Color.accentColor
        case let .remote(slot):
            let palette: [Color] = [.teal, .orange, .purple, .pink]
            return palette[slot % palette.count]
        }
    }
}

/// One speaker turn: a colored name header above its text. The in-flight guess
/// renders muted and italic so the reader can tell it from settled text.
struct SpeakerBlock: View {
    var label: SpeakerLabel
    var text: String
    var volatile: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.displayName)
                .font(.caption.bold())
                .foregroundStyle(label.tint)
            Text(text)
                .foregroundStyle(volatile ? .secondary : .primary)
                .italic(volatile)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
        }
    }
}

/// The live transcript pane: a stack of per-speaker blocks with the live guess
/// trailing as a tentative block. Auto-scrolls to the live edge.
struct LiveTranscriptView: View {
    var transcript: LiveTranscript
    var active: Bool

    private let liveEdge = "live-edge"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if transcript.isEmpty {
                        Text(active ? "Listening…" : "—")
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(transcript.blocks) { block in
                            SpeakerBlock(label: block.label, text: block.text)
                        }
                        if !transcript.volatile.isEmpty {
                            SpeakerBlock(
                                label: transcript.volatileLabel,
                                text: transcript.volatile,
                                volatile: true
                            )
                        }
                    }
                    Color.clear.frame(height: 1).id(liveEdge)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: transcript) {
                withAnimation { proxy.scrollTo(liveEdge, anchor: .bottom) }
            }
        }
    }
}

struct ContentView: View {
    @State private var model = CaptureModel()

    var body: some View {
        VStack(spacing: 16) {
            Text("SayWhat")
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

            LiveTranscriptView(
                transcript: model.transcript,
                active: model.isRecording
            )
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
        }
        .padding(40)
        .frame(minWidth: 560, minHeight: 540)
    }
}

#Preview {
    ContentView()
}
