import Foundation
import SayWhatCore
import SwiftUI

/// The live transcript, grouped into speaker turns. Committed (final) text lands
/// in ``Block``s — consecutive finals from the same speaker merge into one
/// paragraph — and each track's in-flight volatile guess trails as its own
/// tentative block. Two recognizers drive it (one per track, attributed by
/// channel), so the mic and system tracks can each carry a live tail at once
/// without clobbering the other; committed text only ever appends.
struct LiveTranscript: Equatable {
    /// One speaker's contiguous run of committed text.
    struct Block: Equatable, Identifiable {
        let id = UUID()
        var label: SpeakerLabel
        var text: String
    }

    /// One track's latest in-flight guess. Keyed and identified by its source so
    /// the mic and system recognizers update independent tails.
    struct Volatile: Equatable, Identifiable {
        var id: CaptureSource {
            source
        }

        let source: CaptureSource
        var label: SpeakerLabel
        var text: String
    }

    private(set) var blocks: [Block] = []
    /// Each track's latest in-flight guess (a track is absent between
    /// utterances). The two recognizers run concurrently, so both may be present.
    private(set) var volatileBySource: [CaptureSource: Volatile] = [:]

    var isEmpty: Bool {
        blocks.isEmpty && volatileBySource.isEmpty
    }

    /// The in-flight guesses in a stable order (mic before system) for rendering.
    var volatiles: [Volatile] {
        CaptureSource.allCases.compactMap { volatileBySource[$0] }
    }

    /// Commit a final segment from one track: extend the last block if the same
    /// speaker still holds the floor, otherwise start a new one. Clears that
    /// track's volatile tail (the other track's is left untouched).
    mutating func appendFinal(_ text: String, label: SpeakerLabel, source: CaptureSource) {
        volatileBySource[source] = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if var last = blocks.last, last.label == label {
            last.text += " " + trimmed
            blocks[blocks.count - 1] = last
        } else {
            blocks.append(Block(label: label, text: trimmed))
        }
    }

    /// Replace one track's in-flight guess; an empty guess clears its tail.
    mutating func setVolatile(_ text: String, label: SpeakerLabel, source: CaptureSource) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            volatileBySource[source] = nil
        } else {
            volatileBySource[source] = Volatile(source: source, label: label, text: trimmed)
        }
    }
}

extension SpeakerLabel {
    /// Display name for the live view. Remote slots are 0-based; show them 1-based.
    var displayName: String {
        switch self {
        case .you: "You"
        case let .remote(slot): "Speaker \(slot + 1)"
        }
    }

    /// A stable accent color per speaker so turns are scannable at a glance.
    var tint: Color {
        switch self {
        case .you:
            return Color.accentColor
        case let .remote(slot):
            let palette: [Color] = [.teal, .orange, .purple, .pink]
            return palette[slot % palette.count]
        }
    }
}

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
        guard !words.isEmpty else { return Text(text) }
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
        return Text(attributed)
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

/// The live transcript pane: a stack of per-speaker blocks with the live guess
/// trailing as a tentative block. Auto-scrolls to the live edge.
struct LiveTranscriptView: View {
    var transcript: LiveTranscript
    var active: Bool
    /// Remote slot → the enrolled name the live namer recognized mid-meeting, so a
    /// known voice reads as "Eric" instead of "Speaker 2"; empty until matched.
    var names: [Int: String] = [:]
    /// Per-block diagnostic line for the Debug overlay; `nil` (off) shows none.
    var debugLine: ((SpeakerLabel) -> String?)?

    private let liveEdge = "live-edge"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if transcript.isEmpty {
                        Text(active ? "Listening…" : "—")
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(transcript.blocks) { block in
                            SpeakerBlock(
                                label: block.label,
                                text: block.text,
                                name: name(for: block.label),
                                debugLine: debugLine?(block.label)
                            )
                        }
                        ForEach(transcript.volatiles) { guess in
                            SpeakerBlock(
                                label: guess.label,
                                text: guess.text,
                                name: name(for: guess.label),
                                volatile: true,
                                debugLine: debugLine?(guess.label)
                            )
                        }
                    }
                    Color.clear.frame(height: 1).id(liveEdge)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: transcript) {
                withAnimation { proxy.scrollTo(liveEdge, anchor: .bottom) }
            }
        }
    }

    /// The live-recognized name for a label's remote slot, when the namer has
    /// matched one; `nil` for *you* (the mic track) or an as-yet-unmatched slot,
    /// which fall back to the generic "Speaker N".
    private func name(for label: SpeakerLabel) -> String? {
        label.remoteSlot.flatMap { names[$0] }
    }
}

/// The authoritative transcript from the final pass: every utterance as a settled
/// speaker block, in timeline order. Unlike the live view nothing here is
/// volatile — this is the canonical record (DESIGN.md §3).
struct FinalTranscriptView: View {
    var transcript: Transcript
    /// The word the playhead is on, highlighted karaoke-style; `nil` when not
    /// playing or when the transcript has no word timings.
    var cursor: Transcript.WordCursor?
    /// Seek the player when a word is tapped.
    var onSeek: ((Duration) -> Void)?
    /// Rename a remote speaker (by slot) to a persistent name; `nil` disables it.
    var onRename: ((Int, String) -> Void)?
    /// Reassign a single utterance (by id) to a person, correcting one mis-grouped
    /// segment; `nil` disables the per-segment option.
    var onReassign: ((Int, String) -> Void)?
    /// Attendee names offered one-tap in the rename popover; empty shows none.
    var nameSuggestions: [String] = []
    /// Per-utterance diagnostic line for the Debug overlay; `nil` (off) shows none.
    var debugLine: ((Transcript.Utterance) -> String?)?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if transcript.isEmpty {
                        Text("No speech detected.")
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(transcript.utterances) { utterance in
                            SpeakerBlock(
                                label: utterance.speaker,
                                text: utterance.text,
                                name: utterance.speakerName,
                                timestamp: SayWhat.timecode(seconds: Int(utterance.start.seconds)),
                                words: utterance.words,
                                activeWord: cursor?.utteranceID == utterance.id ? cursor?
                                    .wordIndex : nil,
                                onSeek: onSeek,
                                onRename: renameHandler(for: utterance.speaker),
                                onReassign: reassignHandler(for: utterance),
                                nameSuggestions: nameSuggestions,
                                debugLine: debugLine?(utterance)
                            )
                            .id(utterance.id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Follow the playhead, but only when it moves to a new turn — scrolling
            // on every word would fight the reader and never settle.
            .onChange(of: cursor?.utteranceID) { _, utteranceID in
                guard let utteranceID else { return }
                withAnimation { proxy.scrollTo(utteranceID, anchor: .center) }
            }
        }
    }

    /// A per-block rename closure: only remote speakers carry a voiceprint, so
    /// *you* (the mic) and the disabled case (`onRename == nil`) get none.
    private func renameHandler(for speaker: SpeakerLabel) -> ((String) -> Void)? {
        guard let onRename, let slot = speaker.remoteSlot else { return nil }
        return { name in onRename(slot, name) }
    }

    /// A per-segment reassignment closure, capturing the utterance's id; only
    /// remote utterances (which carry a voiceprint) can be reassigned.
    private func reassignHandler(for utterance: Transcript.Utterance) -> ((String) -> Void)? {
        guard let onReassign, utterance.speaker.remoteSlot != nil else { return nil }
        return { name in onReassign(utterance.id, name) }
    }
}
