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
struct SpeakerBlock: View {
    var label: SpeakerLabel
    var text: String
    /// A resolved persistent identity (e.g. "Eric") shown instead of the generic
    /// slot label when the final pass recognized the speaker; `nil` falls back.
    var name: String?
    var volatile: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name ?? label.displayName)
                .font(.caption.bold())
                .foregroundStyle(label.tint)
            Text(text)
                .foregroundStyle(volatile ? .secondary : .primary)
                .italic(volatile)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
        }
    }
}

/// The live transcript pane: a stack of per-speaker blocks with the live guess
/// trailing as a tentative block. Auto-scrolls to the live edge.
struct LiveTranscriptView: View {
    var transcript: LiveTranscript
    var active: Bool

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
                            SpeakerBlock(label: block.label, text: block.text)
                        }
                        ForEach(transcript.volatiles) { guess in
                            SpeakerBlock(label: guess.label, text: guess.text, volatile: true)
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
}

/// The authoritative transcript from the final pass: every utterance as a settled
/// speaker block, in timeline order. Unlike the live view nothing here is
/// volatile — this is the canonical record (DESIGN.md §3).
struct FinalTranscriptView: View {
    var transcript: Transcript

    var body: some View {
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
                            name: utterance.speakerName
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
