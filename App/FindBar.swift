import SayWhatCore
import SwiftUI

/// The in-meeting Find bar (DESIGN.md §11): a query field with the "3 of 12"
/// position, previous/next arrows, and a close button. Shown above the live
/// transcript while recording; matching itself lives in
/// ``TranscriptSearchState`` (SayWhatCore) — this view just binds to it.
struct FindBar: View {
    @Binding var query: String
    /// The current hit list and selection, owned by the pane that also feeds
    /// the transcript views their highlights.
    var search: TranscriptSearchState
    /// Bumped by the Find menu command while the bar is already open, to pull
    /// focus back to the field (the standard ⌘F-again behavior).
    var focusToken: Int
    var onNext: () -> Void
    var onPrevious: () -> Void
    var onClose: () -> Void

    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in meeting", text: $query)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                // Return advances, like every macOS Find bar; Escape closes.
                .onSubmit(onNext)
                .onExitCommand(perform: onClose)
            Text(search.positionLabel ?? (search.query.isEmpty ? "" : "None"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                Button(action: onPrevious) {
                    Image(systemName: "chevron.up")
                }
                .help("Previous match (⇧⌘G)")
                Button(action: onNext) {
                    Image(systemName: "chevron.down")
                }
                .help("Next match (⌘G)")
            }
            .buttonStyle(.borderless)
            .disabled(search.hits.isEmpty)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Done (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar, in: RoundedRectangle(cornerRadius: 8))
        .onAppear { fieldFocused = true }
        .onChange(of: focusToken) { fieldFocused = true }
    }
}

/// An action the Find menu invokes on the focused scene: open the Find bar (⌘F)
/// or step the selection (⌘G / ⇧⌘G). `isAvailable` gates the menu items to a
/// live meeting. Bridged from the pane via `focusedSceneValue`, matching
/// ``ReprocessAction``.
struct FindAction: Equatable {
    let isAvailable: Bool
    let find: () -> Void
    let next: () -> Void
    let previous: () -> Void

    static func == (lhs: FindAction, rhs: FindAction) -> Bool {
        lhs.isAvailable == rhs.isAvailable
    }
}

private struct FindActionKey: FocusedValueKey {
    typealias Value = FindAction
}

extension FocusedValues {
    var find: FindAction? {
        get { self[FindActionKey.self] }
        set { self[FindActionKey.self] = newValue }
    }
}

/// The Find commands, in the standard Edit-menu spot: ⌘F opens (or refocuses)
/// the bar, ⌘G / ⇧⌘G step through matches.
struct FindCommands: Commands {
    @FocusedValue(\.find) private var find

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find in Meeting…") { find?.find() }
                .keyboardShortcut("f")
                .disabled(find?.isAvailable != true)
            Button("Find Next") { find?.next() }
                .keyboardShortcut("g")
                .disabled(find?.isAvailable != true)
            Button("Find Previous") { find?.previous() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(find?.isAvailable != true)
        }
    }
}
