import SwiftUI

/// The app entry point. Phase 0 ships a deliberately bare window that exercises
/// the capture seam end to end (`MicrophoneCapture` → `AudioFrame` stream); the
/// menu-bar UI and real pipelines arrive in later phases.
@main
struct SayWhatApp: App {
    /// Drives the transcript's diagnostic overlays; toggled from the Debug menu and
    /// read by the views via the same `@AppStorage` key.
    @AppStorage(AppSettings.showDebugInfoKey) private var showDebugInfo = false

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
        .commands {
            CommandMenu("Debug") {
                Toggle("Show Debug Info", isOn: $showDebugInfo)
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
        }
    }
}
