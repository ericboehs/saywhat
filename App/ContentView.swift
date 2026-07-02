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
        // Expose the reprocess and import actions to the Debug menu, which can't
        // reach this window's model directly.
        .focusedSceneValue(\.reprocess, ReprocessAction(
            isAvailable: model.canReprocess,
            run: { model.reprocessSelected() }
        ))
        .focusedSceneValue(\.importRecording, ImportAction(
            isAvailable: model.canImport,
            run: { model.importRecording(from: $0) }
        ))
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
    /// Find-in-meeting (⌘F): whether the bar is up, the query as typed, a token
    /// bumped by ⌘F-again to refocus the field, and the hit list + selection.
    @State private var findPresented = false
    @State private var findQuery = ""
    @State private var findFocusToken = 0
    @State private var search = TranscriptSearchState()

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
                if findPresented {
                    FindBar(
                        query: $findQuery,
                        search: search,
                        focusToken: findFocusToken,
                        onNext: { search.next() },
                        onPrevious: { search.previous() },
                        onClose: closeFind
                    )
                }
            }

            // Once the transcript is on screen, the remaining stages (separating,
            // identifying) narrate in a slim strip pinned above it rather than
            // replacing it with a spinner.
            if let status = model.finalizeStatus, model.finalTranscript != nil {
                FinalizeStrip(status: status, fraction: model.finalizeProgress)
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
        // Expose Find to the Edit menu (⌘F / ⌘G / ⇧⌘G); only a live meeting has
        // a Find surface — the final transcript gets search with the library.
        .focusedSceneValue(\.find, FindAction(
            isAvailable: model.isRecording,
            find: presentFind,
            next: { search.next() },
            previous: { search.previous() }
        ))
        .onChange(of: findQuery) { refreshSearch() }
        // The live transcript grows underneath an open Find bar; re-match so
        // new speech joins the hit list (the selection sticks to its hit).
        .onChange(of: model.transcript) { if findPresented { refreshSearch() } }
        .onChange(of: model.isRecording) { _, recording in
            if !recording { closeFind() }
        }
    }

    /// Open the Find bar, or pull focus back to its field when already open.
    private func presentFind() {
        findPresented = true
        findFocusToken += 1
        refreshSearch()
    }

    /// Dismiss the Find bar and drop the highlights; the transcript view
    /// resumes following the live edge.
    private func closeFind() {
        findPresented = false
        findQuery = ""
        search.update(query: "", texts: [])
    }

    private func refreshSearch() {
        search.update(query: findQuery, texts: model.transcript.searchTexts)
    }

    /// The main panel: a live transcript while recording, the editable final
    /// transcript (shown the moment the staged pass produces text, then refined in
    /// place), the pre-transcript finalize spinner, or a placeholder.
    @ViewBuilder private var content: some View {
        if model.isRecording {
            LiveTranscriptView(
                transcript: model.transcript,
                active: true,
                names: model.liveNames,
                debugLine: showDebug ? { model.liveDebugLine(for: $0) } : nil,
                search: findPresented ? search : nil
            )
        } else if let finalTranscript = model.finalTranscript {
            // The staged pass surfaces text first; the top strip narrates the rest.
            transcript(finalTranscript)
        } else if let status = model.finalizeStatus {
            VStack(spacing: 16) {
                Spacer()
                VStack(spacing: 10) {
                    // Determinate when the stage reports a fraction, indeterminate
                    // otherwise — `ProgressView(value:)` renders a spinner for nil.
                    ProgressView(value: model.finalizeProgress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 260)
                    Text(status).foregroundStyle(.secondary)
                }
                Spacer()
                // The source audio is already playable, so offer the transport even
                // before any transcript text lands — pinned at the bottom, clear of
                // the centered status.
                playbackBar
            }
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

/// A slim status strip shown above the transcript while the later final-pass stages
/// (separating, identifying) finish — narrates the stage and how far along it is, so
/// the transcript stays visible and refines in place instead of vanishing behind a
/// spinner. A determinate bar when the stage reports a fraction, indeterminate else.
private struct FinalizeStrip: View {
    let status: String
    let fraction: Double?

    var body: some View {
        HStack(spacing: 10) {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .frame(maxWidth: 180)
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let fraction {
                Text("\(Int(fraction * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar, in: Capsule())
    }
}

#Preview {
    ContentView()
}
