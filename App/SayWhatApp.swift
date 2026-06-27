import SwiftUI

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

        Settings {
            SettingsView()
        }
    }
}
