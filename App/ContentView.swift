import AppKit
import SayWhatCore
import SwiftUI

struct ContentView: View {
    @State private var model = CaptureModel()

    var body: some View {
        NavigationSplitView {
            HistorySidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            DetailPane(model: model)
        }
        .task { model.refreshSessions() }
    }
}

/// The left column: every past recording, newest first, plus the Record/Stop
/// control. Selecting a row reopens that session in the detail pane; the control
/// is disabled mid-finalize so a recording can't be started over an in-flight pass.
private struct HistorySidebar: View {
    @Bindable var model: CaptureModel

    /// Selecting a row reopens it; deselection (nil) is ignored so the detail pane
    /// always has something to show.
    private var selection: Binding<String?> {
        Binding(
            get: { model.selectedSessionID },
            set: { if let id = $0 { model.openSession(id: id) } }
        )
    }

    var body: some View {
        List(model.sessions, selection: selection) { session in
            SessionRow(
                session: session,
                isRecording: model.isRecording && session.id == model.selectedSessionID,
                onDelete: { model.deleteSession(id: session.id) }
            )
        }
        .navigationTitle("Say What")
        .overlay {
            if model.sessions.isEmpty {
                ContentUnavailableView("No recordings", systemImage: "waveform")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button(model.isRecording ? "Stop" : "Record") {
                model.toggle()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(model.isRecording ? .red : .accentColor)
            .disabled(model.finalizeStatus != nil)
            .padding()
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }
}

/// One sidebar row: when the recording started, and a note when it predates saved
/// transcripts (playback only). Right-click reveals the recording in Finder or
/// moves it to the Trash (not offered for the recording in progress).
private struct SessionRow: View {
    let session: RecordedSession
    /// Whether this row is the recording currently in progress.
    var isRecording = false
    /// Move this recording to the Trash.
    var onDelete: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.date.formatted(date: .abbreviated, time: .shortened))
            if isRecording {
                Label("Recording…", systemImage: "record.circle")
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else if !session.hasTranscript {
                Text("Playback only")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([session.directory])
            }
            if !isRecording {
                Divider()
                Button("Move to Trash", role: .destructive, action: onDelete)
            }
        }
    }
}

/// The right column: live meters and transcript while recording, the finalize
/// progress during the pass, then the authoritative transcript (editable) with
/// playback — or a placeholder before anything is selected.
private struct DetailPane: View {
    @Bindable var model: CaptureModel
    /// Mirrors the Debug menu's toggle; when on, the transcript shows per-segment
    /// diagnostics and the voiceprint inspector appears beneath it.
    @AppStorage(AppSettings.showDebugInfoKey) private var showDebug = false

    var body: some View {
        VStack(spacing: 16) {
            if let build = BuildStamp.label {
                Text(build)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }

            if model.isRecording {
                Text("Recording…").foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 16) {
                    TrackRow(title: "Microphone", level: model.micLevel, active: true)
                    TrackRow(title: "System audio", level: model.systemLevel, active: true)
                }
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showDebug {
                VoiceprintInspector(model: model)
            }

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
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 540)
    }

    /// The main panel: finalize progress, a live transcript while recording, the
    /// editable final transcript with playback, or a placeholder.
    @ViewBuilder private var content: some View {
        if let status = model.finalizeStatus {
            VStack(spacing: 10) {
                ProgressView()
                Text(status).foregroundStyle(.secondary)
            }
        } else if model.isRecording {
            LiveTranscriptView(
                transcript: model.transcript,
                active: true,
                names: model.liveNames,
                debugLine: showDebug ? { model.liveDebugLine(for: $0) } : nil
            )
        } else if let finalTranscript = model.finalTranscript {
            transcript(finalTranscript)
        } else if model.selectedSessionID != nil {
            placeholder("This recording has no saved transcript.", systemImage: "text.badge.xmark")
                .overlay(alignment: .bottom) { playbackBar }
        } else {
            placeholder("Select a recording, or press Record.", systemImage: "waveform")
        }
    }

    /// The authoritative transcript, editable, with the playback bar beneath it.
    private func transcript(_ transcript: Transcript) -> some View {
        VStack(spacing: 12) {
            FinalTranscriptView(
                transcript: transcript,
                cursor: model.playback.flatMap { transcript.wordCursor(at: $0.currentTime) },
                onSeek: { model.playback?.seek(to: $0) },
                onRename: { slot, name in model.renameSpeaker(slot: slot, to: name) },
                onReassign: { id, name in model.reassignUtterance(id: id, to: name) },
                debugLine: showDebug ? { model.debugLine(for: $0) } : nil
            )
            playbackBar
        }
    }

    @ViewBuilder private var playbackBar: some View {
        if let playback = model.playback {
            PlaybackBar(playback: playback)
        }
    }

    private func placeholder(_ title: String, systemImage: String) -> some View {
        ContentUnavailableView(title, systemImage: systemImage)
    }
}

#Preview {
    ContentView()
}
