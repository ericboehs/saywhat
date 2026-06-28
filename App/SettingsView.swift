import SwiftUI

/// Keys and defaults for user settings, shared between the ``SettingsView`` that
/// edits them and the model that reads them at run time. Kept in one place so the
/// stored key and its default never drift apart.
enum AppSettings {
    /// How leniently the final pass matches a meeting's voices to enrolled
    /// speakers — `0` keeps near-identical voices apart, `1` merges loosely.
    /// Persisted; read by the final pass to derive the matcher threshold.
    static let fuzzinessKey = "speakerMatchFuzziness"
    static let defaultFuzziness = 0.5

    /// Whether the transcript shows diagnostic overlays — per-segment diarizer
    /// slot and voiceprint match score, the live namer's running matches, and a
    /// voiceprint-directory inspector. Off by default; toggled from the Debug menu.
    static let showDebugInfoKey = "showDebugInfo"

    /// The cosine-similarity threshold the current fuzziness maps to. Higher
    /// fuzziness loosens matching (a lower threshold), so one person's varied
    /// takes collapse onto a single voiceprint instead of splitting into several.
    /// The 0.25…0.75 window brackets the conservative 0.5 default both ways.
    static var matchThreshold: Float {
        let store = UserDefaults.standard
        let fuzziness = store.object(forKey: fuzzinessKey) == nil
            ? defaultFuzziness
            : store.double(forKey: fuzzinessKey)
        return Float(0.75 - fuzziness.clamped(to: 0 ... 1) * 0.5)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// The app's settings window (⌘,). Currently just speaker-matching fuzziness;
/// more controls land here as the pipelines grow user-facing knobs.
struct SettingsView: View {
    @AppStorage(AppSettings.fuzzinessKey) private var fuzziness = AppSettings.defaultFuzziness

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Slider(value: $fuzziness, in: 0 ... 1, step: 0.05) {
                        Text("Speaker matching")
                    } minimumValueLabel: {
                        Text("Strict")
                    } maximumValueLabel: {
                        Text("Loose")
                    }
                    Text(
                        """
                        Higher merges a person's varied takes onto one name; \
                        lower keeps similar voices apart. Applies to the final \
                        transcript when a recording finishes.
                        """
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("Speaker recognition")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}
