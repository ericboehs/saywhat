import SayWhatCore
import SwiftUI

/// Drives a single ``MicrophoneCapture`` session and counts the frames it
/// yields — the smallest thing that proves the hardware seam is wired into the
/// app target. Not the live pipeline; that lands in Phase 1.
@MainActor
@Observable
final class CaptureModel {
    private(set) var isRecording = false
    private(set) var frameCount = 0
    private(set) var sampleCount = 0
    /// Smoothed input level in `0...1` for the meter (see `meterLevel`).
    private(set) var level: Float = 0
    private(set) var errorMessage: String?

    private let microphone = MicrophoneCapture()
    private var pump: Task<Void, Never>?

    func toggle() {
        if isRecording { stop() } else { start() }
    }

    private func start() {
        isRecording = true
        frameCount = 0
        sampleCount = 0
        level = 0
        errorMessage = nil
        pump = Task { [microphone] in
            do {
                let frames = try await microphone.start()
                for await frame in frames {
                    frameCount += 1
                    sampleCount += frame.samples.count
                    // Attack fast, release slow — a meter that snaps up to peaks
                    // but eases back so it reads instead of flickering.
                    let target = frame.meterLevel()
                    level = target > level ? target : level * 0.8 + target * 0.2
                }
            } catch {
                errorMessage = String(describing: error)
                isRecording = false
            }
        }
    }

    private func stop() {
        isRecording = false
        pump?.cancel()
        pump = nil
        level = 0
        Task { [microphone] in await microphone.stop() }
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

struct ContentView: View {
    @State private var model = CaptureModel()

    var body: some View {
        VStack(spacing: 16) {
            Text("SayWhat")
                .font(.largeTitle.bold())
            Text(model.isRecording ? "Recording…" : "Idle")
                .foregroundStyle(.secondary)
            LevelMeter(level: model.level)
                .frame(maxWidth: 240)
                .opacity(model.isRecording ? 1 : 0.35)
            Text("\(model.frameCount) frames · \(model.sampleCount) samples")
                .monospacedDigit()
                .font(.callout)
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
        .frame(minWidth: 360, minHeight: 240)
    }
}

#Preview {
    ContentView()
}
