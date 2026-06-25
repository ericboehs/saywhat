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
        errorMessage = nil
        pump = Task { [microphone] in
            do {
                let frames = try await microphone.start()
                for await frame in frames {
                    frameCount += 1
                    sampleCount += frame.samples.count
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
        Task { [microphone] in await microphone.stop() }
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
