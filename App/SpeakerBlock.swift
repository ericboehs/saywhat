import Foundation
import SayWhatCore
import SwiftUI

/// One speaker turn: a colored name header above its text. The in-flight guess
/// renders muted and italic so the reader can tell it from settled text.
/// Whether a name edit targets the speaker's whole group or just one segment.
enum RenameScope: Hashable {
    case wholeSpeaker
    case thisSegment
}

struct SpeakerBlock: View {
    var label: SpeakerLabel
    var text: String
    /// A resolved persistent identity (e.g. "Eric") shown instead of the generic
    /// slot label when the final pass recognized the speaker; `nil` falls back.
    var name: String?
    var volatile: Bool = false
    /// When this turn started, as a `M:SS` timecode shown beside the speaker
    /// name; `nil` (the live view) shows no timestamp.
    var timestamp: String?
    /// Per-word timings for this turn; when present the text is rendered word by
    /// word so the spoken one can be highlighted during playback.
    var words: [WordTiming] = []
    /// The index of the word the playhead is on, highlighted; `nil` highlights none.
    var activeWord: Int?
    /// Seek the player to a word's start when it's clicked. `nil` disables seeking.
    var onSeek: ((Duration) -> Void)?
    /// Commit a new name for this speaker's whole group (double-click the name to
    /// rename); `nil` — the live view, or *you* — makes the name a plain,
    /// non-editable label.
    var onRename: ((String) -> Void)?
    /// Commit a new name for **just this segment**, correcting one utterance the
    /// diarizer mis-grouped; `nil` hides the per-segment option (only whole-speaker
    /// rename is offered).
    var onReassign: ((String) -> Void)?
    /// Names to offer one-tap in the rename popover — the meeting's attendee
    /// roster (DESIGN.md §6). Empty shows the plain free-text editor.
    var nameSuggestions: [String] = []
    /// A diagnostic line (slot, resolved identity, match score) shown beneath the
    /// name when the Debug overlay is on; `nil` hides it.
    var debugLine: String?
    /// Find-bar matches within this turn's text, as character-offset ranges to
    /// wash in highlight color; empty when Find is closed or matched nothing here.
    var highlights: [Range<Int>] = []
    /// The selected Find match, highlighted stronger; `nil` when it isn't in
    /// this turn.
    var activeHighlight: Range<Int>?

    /// Whether the rename popover is open, its in-progress text, and whether the
    /// edit targets the whole speaker (default) or just this one segment.
    @State private var isRenaming = false
    @State private var draftName = ""
    @State private var scope: RenameScope = .wholeSpeaker
    /// Whether the pointer is over a renameable name, fading in the pencil hint.
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                speakerName
                if let timestamp {
                    Text(timestamp)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            if let debugLine {
                Text(debugLine)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            content
                .foregroundStyle(volatile ? .secondary : .primary)
                .italic(volatile)
                .tint(volatile ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                // One wrapping, selectable `Text`: drag to select/copy while
                // paused. Each word is a `saywhat://seek` link so a click seeks —
                // handled here, never leaving the app.
                .textSelection(.enabled)
                .environment(\.openURL, OpenURLAction { url in seek(url) })
        }
    }

    /// The colored speaker name. When the turn is renameable (a remote speaker in
    /// the final view), a double-click opens a popover to set a persistent name;
    /// otherwise it's a plain label. Double-click — not single — so it never
    /// fights selecting the transcript text.
    @ViewBuilder private var speakerName: some View {
        let text = Text(name ?? label.displayName)
            .font(.caption.bold())
            .foregroundStyle(label.tint)
        if let onRename {
            HStack(spacing: 4) {
                text
                // A pencil on hover hints that the name is clickable. It keeps its
                // slot at zero opacity so fading it in never reflows the header.
                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundStyle(label.tint)
                    .opacity(isHovering ? 0.7 : 0)
                    .animation(.easeInOut(duration: 0.12), value: isHovering)
            }
            .contentShape(.rect)
            .help("Click to rename this speaker")
            .onHover { isHovering = $0 }
            .onTapGesture {
                draftName = name ?? label.displayName
                scope = .wholeSpeaker
                isRenaming = true
            }
            .popover(isPresented: $isRenaming, arrowEdge: .bottom) {
                renamePopover(rename: onRename)
            }
        } else {
            text
        }
    }

    /// The rename editor: type a name, Return or Save persists it; Escape/dismiss
    /// cancels. When per-segment reassignment is available, a scope picker chooses
    /// between renaming the whole speaker (default) and correcting just this one
    /// segment the diarizer mis-grouped.
    private func renamePopover(rename: @escaping (String) -> Void) -> some View {
        func save() {
            if scope == .thisSegment, let onReassign {
                onReassign(draftName)
            } else {
                rename(draftName)
            }
            isRenaming = false
        }
        return VStack(alignment: .leading, spacing: 8) {
            if onReassign != nil {
                Picker("", selection: $scope) {
                    Text("Whole speaker").tag(RenameScope.wholeSpeaker)
                    Text("Just this segment").tag(RenameScope.thisSegment)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } else {
                Text("Speaker name")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField("Name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit(save)
            if !suggestionMatches.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(suggestionMatches, id: \.self) { suggestion in
                        Button {
                            draftName = suggestion
                            save()
                        } label: {
                            Label(suggestion, systemImage: "person.crop.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }

    /// The attendee suggestions to show under the name field: all of them until
    /// the user starts typing something new, then narrowed to matches, capped so
    /// a big invite doesn't swallow the popover.
    private var suggestionMatches: [String] {
        let draft = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let untouched = draft.isEmpty || draft == (name ?? label.displayName)
        let matches = untouched
            ? nameSuggestions
            : nameSuggestions.filter { $0.localizedCaseInsensitiveContains(draft) }
        return Array(matches.prefix(5))
    }

    /// The turn's text — each word a link carrying its start time, the active word
    /// background-highlighted. One `Text` so it wraps and stays selectable; the
    /// link runs make words clickable without splitting them into separate views
    /// (which would defeat wrapping).
    private var content: Text {
        guard !words.isEmpty else { return Text(searchHighlighted(AttributedString(text))) }
        var attributed = AttributedString()
        for (index, word) in words.enumerated() {
            if index > 0 { attributed += AttributedString(" ") }
            var run = AttributedString(word.text)
            // Override the link tint so words read as plain transcript text.
            run.foregroundColor = volatile ? .secondary : .primary
            if onSeek != nil {
                run.link = URL(string: "saywhat://seek?t=\(word.range.lowerBound.seconds)")
            }
            if index == activeWord {
                // Highlight only — no bold, which would change the word's width
                // and reflow the line as the playhead moves.
                run.backgroundColor = label.tint.opacity(0.3)
            }
            attributed += run
        }
        return Text(searchHighlighted(attributed))
    }

    /// Wash Find matches into the rendered text in yellow, the selected one
    /// stronger. Character offsets come from ``TranscriptSearchState`` over the
    /// same text this block renders — plain `text`, or the word runs joined by
    /// spaces (see ``Transcript/searchTexts``) — so they apply to either path.
    /// Out-of-bounds ranges (a volatile guess revised mid-update) are skipped
    /// rather than clamped. A search wash beats the playhead's on overlap; the
    /// match is what the reader asked to see.
    private func searchHighlighted(_ base: AttributedString) -> AttributedString {
        var attributed = base
        for range in highlights {
            let characters = attributed.characters
            guard range.lowerBound >= 0, range.upperBound <= characters.count else { continue }
            let lower = characters.index(characters.startIndex, offsetBy: range.lowerBound)
            let upper = characters.index(lower, offsetBy: range.count)
            attributed[lower ..< upper].backgroundColor = .yellow
                .opacity(range == activeHighlight ? 0.55 : 0.25)
        }
        return attributed
    }

    /// Handle a word-link click by seeking the player to its encoded start time.
    private func seek(_ url: URL) -> OpenURLAction.Result {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        guard url.scheme == "saywhat",
              let value = items?.first(where: { $0.name == "t" })?.value,
              let seconds = Double(value)
        else { return .systemAction }
        onSeek?(.seconds(seconds))
        return .handled
    }
}
