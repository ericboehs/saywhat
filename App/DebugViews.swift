import SayWhatCore
import SwiftUI

/// The Debug overlay's voiceprint inspector: every enrolled person with their
/// exemplar count and a short id, so duplicate identities — two "Zwag" rows that
/// should be one voice — are visible at a glance. Read-only; merging duplicates is
/// a separate, deliberate action. Loads on appear and refreshes on demand, since
/// the directory changes underneath it as renames mint and bind voiceprints.
struct VoiceprintInspector: View {
    var model: CaptureModel

    /// Names that appear on more than one person — the likely duplicates to merge.
    private var duplicateNames: Set<String> {
        let names = model.voiceprintDirectory.map(\.person.name)
        let counts = Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +)
        return Set(counts.filter { $0.value > 1 }.keys)
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                if model.voiceprintDirectory.isEmpty {
                    Text("No enrolled voiceprints.")
                        .foregroundStyle(.tertiary)
                } else {
                    if !duplicateNames.isEmpty {
                        Label(
                            "\(duplicateNames.count) name(s) appear on more than one person — likely duplicates.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                    }
                    ForEach(model.voiceprintDirectory, id: \.person.id) { entry in
                        row(entry)
                    }
                }
            }
            .font(.system(.caption, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            HStack {
                Text("Voiceprint directory (\(model.voiceprintDirectory.count))")
                    .font(.caption.bold())
                Spacer()
                Button {
                    model.loadVoiceprintDirectory()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Reload the voiceprint directory")
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        .task { model.loadVoiceprintDirectory() }
    }

    /// One person: a duplicate marker, the name, its short id, and how many
    /// exemplars (recordings) are bound to it.
    private func row(_ entry: EnrolledPerson) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .opacity(duplicateNames.contains(entry.person.name) ? 1 : 0)
            Text(entry.person.name)
                .foregroundStyle(.primary)
            Text(CaptureModel.shortID(entry.person.id))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(entry.exemplars.count) print\(entry.exemplars.count == 1 ? "" : "s")")
                .foregroundStyle(.secondary)
            mergeMenu(entry)
        }
        .textSelection(.enabled)
    }

    /// A "merge into…" menu folding this person's voiceprints into another (the
    /// fix for a duplicate). Lists every other enrolled person; disabled when this
    /// is the only one.
    private func mergeMenu(_ entry: EnrolledPerson) -> some View {
        let others = model.voiceprintDirectory.filter { $0.person.id != entry.person.id }
        return Menu {
            ForEach(others, id: \.person.id) { other in
                Button("\(other.person.name) [\(CaptureModel.shortID(other.person.id))]") {
                    model.mergeVoiceprints(entry.person.id, into: other.person.id)
                }
            }
        } label: {
            Image(systemName: "arrow.triangle.merge")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(others.isEmpty)
        .help("Merge this person's voiceprints into another")
    }
}
