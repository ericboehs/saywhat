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

    /// The transcript as the flat text list `TranscriptSearchState` matches over,
    /// in render order: committed blocks, then the volatile tails. Entry indexes
    /// in search hits index into this same order.
    var searchTexts: [String] {
        blocks.map(\.text) + volatiles.map(\.text)
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
    /// The Find bar's matches over this transcript; `nil` (Find closed) shows no
    /// highlights and keeps the view pinned to the live edge.
    var search: TranscriptSearchState?

    private let liveEdge = "live-edge"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if transcript.isEmpty {
                        Text(active ? "Listening…" : "—")
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(
                            Array(transcript.blocks.enumerated()),
                            id: \.element.id
                        ) { index, block in
                            SpeakerBlock(
                                label: block.label,
                                text: block.text,
                                name: name(for: block.label),
                                debugLine: debugLine?(block.label),
                                highlights: search?.offsets(inEntry: index) ?? [],
                                activeHighlight: activeHighlight(entry: index)
                            )
                        }
                        ForEach(
                            Array(transcript.volatiles.enumerated()),
                            id: \.element.id
                        ) { index, guess in
                            let entry = transcript.blocks.count + index
                            SpeakerBlock(
                                label: guess.label,
                                text: guess.text,
                                name: name(for: guess.label),
                                volatile: true,
                                debugLine: debugLine?(guess.label),
                                highlights: search?.offsets(inEntry: entry) ?? [],
                                activeHighlight: activeHighlight(entry: entry)
                            )
                        }
                    }
                    Color.clear.frame(height: 1).id(liveEdge)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: transcript) {
                // While Find is open, new speech must not yank the reader off the
                // match they're looking at; the live edge resumes on close.
                guard search == nil else { return }
                withAnimation { proxy.scrollTo(liveEdge, anchor: .bottom) }
            }
            .onChange(of: search?.currentHit, initial: true) { _, hit in
                guard let hit else { return }
                scroll(to: hit, proxy: proxy)
            }
        }
    }

    /// Center the selected match's block. Entry indexes count committed blocks
    /// then volatile tails, mirroring ``LiveTranscript/searchTexts``.
    private func scroll(to hit: TranscriptSearchHit, proxy: ScrollViewProxy) {
        if hit.entry < transcript.blocks.count {
            withAnimation { proxy.scrollTo(transcript.blocks[hit.entry].id, anchor: .center) }
        } else {
            let volatiles = transcript.volatiles
            let index = hit.entry - transcript.blocks.count
            guard index < volatiles.count else { return }
            withAnimation { proxy.scrollTo(volatiles[index].id, anchor: .center) }
        }
    }

    /// The selected match's range when it lands in `entry`; `nil` otherwise.
    private func activeHighlight(entry: Int) -> Range<Int>? {
        guard let hit = search?.currentHit, hit.entry == entry else { return nil }
        return hit.offsets
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
    /// The Find bar's matches over this transcript; `nil` (Find closed) shows no
    /// highlights. Entry indexes are utterance positions, mirroring
    /// ``Transcript/searchTexts``.
    var search: TranscriptSearchState?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if transcript.isEmpty {
                        Text("No speech detected.")
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(
                            Array(transcript.utterances.enumerated()),
                            id: \.element.id
                        ) { entry, utterance in
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
                                debugLine: debugLine?(utterance),
                                highlights: search?.offsets(inEntry: entry) ?? [],
                                activeHighlight: activeHighlight(entry: entry)
                            )
                            .id(utterance.id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Follow the playhead, but only when it moves to a new turn — scrolling
            // on every word would fight the reader and never settle. While Find is
            // open the match owns the scroll position instead.
            .onChange(of: cursor?.utteranceID) { _, utteranceID in
                guard search == nil, let utteranceID else { return }
                withAnimation { proxy.scrollTo(utteranceID, anchor: .center) }
            }
            .onChange(of: search?.currentHit, initial: true) { _, hit in
                guard let hit, hit.entry < transcript.utterances.count else { return }
                withAnimation {
                    proxy.scrollTo(transcript.utterances[hit.entry].id, anchor: .center)
                }
            }
        }
    }

    /// The selected match's range when it lands in `entry`; `nil` otherwise.
    private func activeHighlight(entry: Int) -> Range<Int>? {
        guard let hit = search?.currentHit, hit.entry == entry else { return nil }
        return hit.offsets
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
