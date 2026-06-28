import Foundation
import SayWhatCore

extension CaptureModel {
    /// A timestamped session directory under our bundle-namespaced Application
    /// Support, e.g. `…/Application Support/com.boehs.saywhat/Recordings/session-1750876200`.
    ///
    /// The bundle-id namespace keeps us from writing loose folders into the
    /// shared `~/Library/Application Support`. A sandboxed build does this via
    /// its container, but an unsigned dev build runs unsandboxed against the
    /// real directory, so we namespace explicitly.
    static func newSessionDirectory() -> URL {
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

    /// Open the persistent voiceprint database under our bundle-namespaced
    /// Application Support (alongside `Recordings/`). Returns `nil` if it can't be
    /// opened — the final pass then falls back to generic `Speaker N` labels
    /// rather than failing. On-device only; nothing here leaves the machine.
    static func voiceprintStore() -> VoiceprintStore? {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let namespace = Bundle.main.bundleIdentifier ?? "SayWhat"
        let directory = base.appendingPathComponent(namespace, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("voiceprints.sqlite").path
        return try? VoiceprintStore(path: path)
    }
}
