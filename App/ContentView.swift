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

    /// The live transcript of the mixed mic+system audio.
    private(set) var transcript = LiveTranscript()

    private(set) var sessionPath: String?
    private(set) var errorMessage: String?

    private let microphone = MicrophoneCapture()
    private let system = SystemAudioCapture()
    private let transcriber = AppleSpeechTranscriber(source: .microphone)
    private var recording: Task<Void, Never>?

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
        errorMessage = nil

        let session = RecordingSession(directory: Self.newSessionDirectory())
        sessionPath = session.directory.path

        recording = Task { [microphone, system] in
            do {
                try session.createDirectory()
                let micWriter = try session.writer(for: .microphone)
                let systemWriter = try session.writer(for: .system)

                // One mixer sums both tracks for the single live transcriber;
                // claim its output stream before the pumps start feeding it.
                let mixer = AudioMixer()
                let mixed = await mixer.output()

                // Transcribe the mix while both tracks are captured, metered,
                // stored, and fed into the mixer concurrently. Each loop ends
                // when its source finishes (i.e. after stop()).
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await self.transcribeMixed(mixed) }
                    group.addTask {
                        await self.pump(
                            microphone,
                            into: micWriter,
                            source: .microphone,
                            mixer: mixer
                        )
                    }
                    group.addTask {
                        await self.pump(
                            system,
                            into: systemWriter,
                            source: .system,
                            mixer: mixer
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
    /// Each frame fans out to the durable writer (storage) and the shared
    /// ``AudioMixer`` (live transcript); a write failure surfaces its message
    /// without tearing down capture or the other track. On end, the track is
    /// marked finished on the mixer so the mixed stream can wind down.
    private func pump(
        _ capture: any AudioCapture,
        into writer: DurableAACWriter,
        source: CaptureSource,
        mixer: AudioMixer
    ) async {
        do {
            let frames = try await capture.start()
            for await frame in frames {
                update(source, with: frame)
                await mixer.feed(source, frame.samples)
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
        await mixer.finish(source)
    }

    /// Drain the mixed transcriber's segments into the live transcript.
    /// Transcription failures (e.g. denied speech permission) surface as a
    /// message and never affect capture or storage.
    private func transcribeMixed(_ frames: AsyncStream<AudioFrame>) async {
        do {
            for try await segment in try await transcriber.transcribe(frames) {
                transcript.apply(segment)
            }
        } catch {
            errorMessage = "transcribe: \(error)"
        }
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

/// The live transcript of the mixed audio: a single growing stream of committed
/// (final) text with the in-flight volatile guess trailing in muted italic.
/// Because one recognizer drives it, text only ever appends — a volatile tail
/// firms up into final text and is replaced by the next guess; nothing already
/// shown is retracted.
struct LiveTranscript: Equatable {
    /// Committed final text, accumulated in arrival order.
    private(set) var finals: [String] = []
    /// The latest in-flight volatile guess (empty between utterances).
    private(set) var volatile = ""

    var isEmpty: Bool {
        finals.isEmpty && volatile.isEmpty
    }

    /// Fold one recognizer result in: a final commits and clears the volatile
    /// tail; a volatile just replaces the current tail.
    mutating func apply(_ segment: TranscriptSegment) {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if segment.isFinal {
            if !text.isEmpty { finals.append(text) }
            volatile = ""
        } else {
            volatile = text
        }
    }
}

/// The live transcript pane: committed text in the primary color with the live
/// volatile guess trailing in muted italic. Auto-scrolls to the live edge.
struct LiveTranscriptView: View {
    var transcript: LiveTranscript
    var active: Bool

    private let liveEdge = "live-edge"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if transcript.isEmpty {
                        Text(active ? "Listening…" : "—")
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(styled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                Color.clear.frame(height: 1).id(liveEdge)
            }
            .onChange(of: transcript) {
                withAnimation { proxy.scrollTo(liveEdge, anchor: .bottom) }
            }
        }
    }

    /// Committed text as flowing prose, with the still-volatile guess appended
    /// in muted italic so the reader can tell settled text from the live edge.
    private var styled: AttributedString {
        var result = AttributedString(transcript.finals.joined(separator: " "))
        if !transcript.volatile.isEmpty {
            if !result.characters.isEmpty { result += AttributedString(" ") }
            var tail = AttributedString(transcript.volatile)
            tail.foregroundColor = .secondary
            tail.font = .body.italic()
            result += tail
        }
        return result
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
