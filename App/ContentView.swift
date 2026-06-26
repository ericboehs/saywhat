import Foundation
import SayWhatCore
import SwiftUI

/// Drives both capture tracks (``MicrophoneCapture`` + ``SystemAudioCapture``),
/// meters each, and persists each to durable AAC via a per-track
/// ``DurableAACWriter`` in a ``RecordingSession``. The first end-to-end proof
/// that a Record press produces a recoverable, dual-track recording on disk.
/// Not yet the live transcript pipeline; that lands in Phase 1.
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

    private(set) var sessionPath: String?
    private(set) var errorMessage: String?

    private let microphone = MicrophoneCapture()
    private let system = SystemAudioCapture()
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
        errorMessage = nil

        let session = RecordingSession(directory: Self.newSessionDirectory())
        sessionPath = session.directory.path

        recording = Task { [microphone, system] in
            do {
                try session.createDirectory()
                let micWriter = try session.writer(for: .microphone)
                let systemWriter = try session.writer(for: .system)

                // Drain both tracks concurrently; each loop ends when its
                // capture stream finishes (i.e. after stop()).
                await withTaskGroup(of: Void.self) { group in
                    group
                        .addTask {
                            await self.pump(microphone, into: micWriter, source: .microphone)
                        }
                    group.addTask { await self.pump(system, into: systemWriter, source: .system) }
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

    /// Meter and persist one track's frames until its stream finishes. A track's
    /// failure surfaces its message without tearing down the other track.
    private func pump(
        _ capture: any AudioCapture,
        into writer: DurableAACWriter,
        source: CaptureSource
    ) async {
        do {
            let frames = try await capture.start()
            for await frame in frames {
                update(source, with: frame)
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

    /// A timestamped session directory in the app container's Application
    /// Support, e.g. `…/Recordings/session-1750876200`.
    private static func newSessionDirectory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let stamp = Int(Date().timeIntervalSince1970)
        return base
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
        }
        .padding(40)
        .frame(minWidth: 360, minHeight: 320)
    }
}

#Preview {
    ContentView()
}
