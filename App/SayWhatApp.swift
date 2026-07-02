import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The app entry point. Phase 0 ships a deliberately bare window that exercises
/// the capture seam end to end (`MicrophoneCapture` → `AudioFrame` stream); the
/// menu-bar UI and real pipelines arrive in later phases.
@main
struct SayWhatApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
        .commands {
            FindCommands()
            DebugCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

/// The Debug menu: the diagnostic-overlay toggle plus the reprocess action. Split
/// into its own `Commands` type so `@FocusedValue` and `@AppStorage` re-evaluate
/// as scene focus and settings change — a plain App body wouldn't.
struct DebugCommands: Commands {
    @AppStorage(AppSettings.showDebugInfoKey) private var showDebugInfo = false
    /// The reprocess action published by the focused scene, or `nil` when no window
    /// is focused. The model owns availability; the menu just relays the click.
    @FocusedValue(\.reprocess) private var reprocess
    /// The import action published by the focused scene. The menu presents the file
    /// picker and hands the chosen URL back to the model.
    @FocusedValue(\.importRecording) private var importRecording

    var body: some Commands {
        CommandMenu("Debug") {
            Toggle("Show Debug Info", isOn: $showDebugInfo)
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            Button("Reprocess Transcript") { reprocess?.run() }
                .disabled(reprocess?.isAvailable != true)
            Button("Import Recording…") { presentImportPanel() }
                .disabled(importRecording?.isAvailable != true)
        }
    }

    /// Show an open panel for a single audio file and hand the choice to the model.
    /// The panel grants the sandboxed app read access to the picked file, which the
    /// import copies into the app's own container.
    private func presentImportPanel() {
        guard let importRecording, importRecording.isAvailable else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an audio recording to transcribe."
        if panel.runModal() == .OK, let url = panel.url {
            importRecording.run(url)
        }
    }
}

/// An action the Debug menu can invoke on the focused scene: re-run the final pass
/// over the selected recording. `isAvailable` gates the menu item; `run` performs
/// it. Bridged from the model via `focusedSceneValue` so a menu command can reach
/// the window's `@State` model.
struct ReprocessAction: Equatable {
    let isAvailable: Bool
    let run: () -> Void

    static func == (lhs: ReprocessAction, rhs: ReprocessAction) -> Bool {
        lhs.isAvailable == rhs.isAvailable
    }
}

private struct ReprocessActionKey: FocusedValueKey {
    typealias Value = ReprocessAction
}

extension FocusedValues {
    var reprocess: ReprocessAction? {
        get { self[ReprocessActionKey.self] }
        set { self[ReprocessActionKey.self] = newValue }
    }
}

/// An action the Debug menu can invoke on the focused scene: import an external
/// audio file as a new session and transcribe it. `isAvailable` gates the menu
/// item; `run` takes the picked file's URL. Bridged from the model via
/// `focusedSceneValue`, like ``ReprocessAction``.
struct ImportAction: Equatable {
    let isAvailable: Bool
    let run: (URL) -> Void

    static func == (lhs: ImportAction, rhs: ImportAction) -> Bool {
        lhs.isAvailable == rhs.isAvailable
    }
}

private struct ImportActionKey: FocusedValueKey {
    typealias Value = ImportAction
}

extension FocusedValues {
    var importRecording: ImportAction? {
        get { self[ImportActionKey.self] }
        set { self[ImportActionKey.self] = newValue }
    }
}
