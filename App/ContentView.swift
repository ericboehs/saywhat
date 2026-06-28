import SayWhatCore
import SwiftUI

struct ContentView: View {
    @State private var model = CaptureModel()

    var body: some View {
        VStack(spacing: 16) {
            Text("Say What")
                .font(.largeTitle.bold())
            if let build = BuildStamp.label {
                Text(build)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
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
                            onSeek: { model.playback?.seek(to: $0) },
                            onRename: { slot, name in model.renameSpeaker(slot: slot, to: name) }
                        )
                        if let playback = model.playback {
                            PlaybackBar(playback: playback)
                        }
                    }
                } else {
                    LiveTranscriptView(
                        transcript: model.transcript,
                        active: model.isRecording,
                        names: model.liveNames
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
