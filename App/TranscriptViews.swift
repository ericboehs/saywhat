import Foundation
import SayWhatCore
import SwiftUI

/// The live transcript of the mixed audio, grouped into speaker turns. Committed
/// (final) text lands in ``Block``s — consecutive finals from the same speaker
/// merge into one paragraph — and the in-flight volatile guess trails as its own
/// tentative block. One recognizer drives it, so text only ever appends; nothing
/// already shown is retracted.
struct LiveTranscript: Equatable {
    /// One speaker's contiguous run of committed text.
    struct Block: Equatable, Identifiable {
        let id = UUID()
        var label: SpeakerLabel
        var text: String
    }

    private(set) var blocks: [Block] = []
    /// The latest in-flight volatile guess (empty between utterances).
    private(set) var volatile = ""
    /// Best-guess speaker for the volatile tail.
    private(set) var volatileLabel: SpeakerLabel = .you

    var isEmpty: Bool {
        blocks.isEmpty && volatile.isEmpty
    }

    /// Commit a final segment: extend the last block if the same speaker still
    /// holds the floor, otherwise start a new one. Clears the volatile tail.
    mutating func appendFinal(_ text: String, label: SpeakerLabel) {
        volatile = ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if var last = blocks.last, last.label == label {
            last.text += " " + trimmed
            blocks[blocks.count - 1] = last
        } else {
            blocks.append(Block(label: label, text: trimmed))
        }
    }

    /// Replace the in-flight guess and its speaker.
    mutating func setVolatile(_ text: String, label: SpeakerLabel) {
        volatile = text.trimmingCharacters(in: .whitespacesAndNewlines)
        volatileLabel = label
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
    var volatile: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.displayName)
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
                        if !transcript.volatile.isEmpty {
                            SpeakerBlock(
                                label: transcript.volatileLabel,
                                text: transcript.volatile,
                                volatile: true
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
                        SpeakerBlock(label: utterance.speaker, text: utterance.text)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
