import Foundation
import SayWhatCore

/// Diagnostics for the Debug overlay (toggled from the Debug menu): per-segment
/// slot/identity/score lines and the enrolled-voiceprint directory. All
/// observational — nothing here mutates the transcript or the store; it just reads
/// state the pipeline already produced so the user can see *why* speakers split or
/// where duplicate voiceprints came from.
extension CaptureModel {
    /// A one-line diagnostic for a final-transcript utterance: its diarizer slot,
    /// the identity that slot resolved to (person + short id, or an un-named mint),
    /// and how similar this segment's *own* voiceprint is to that identity's
    /// exemplar — a low similarity on a confidently-named block is the tell that the
    /// segment was mis-grouped. `nil` for *you* (the mic), which has no slot.
    func debugLine(for utterance: Transcript.Utterance) -> String? {
        guard let slot = utterance.speaker.remoteSlot else { return nil }
        var parts = ["slot \(slot)"]
        if let resolved = speakers[slot] {
            if let person = resolved.person {
                parts.append("→ \(person.name) [\(Self.shortID(person.id))]")
            } else {
                parts.append("→ mint")
            }
            if let voiceprint = utteranceVoiceprints[utterance.id] {
                let score = VoiceprintMatcher.cosineSimilarity(
                    voiceprint.embedding, resolved.exemplar.embedding
                )
                parts.append(String(format: "sim %.2f", score))
            }
        }
        return parts.joined(separator: "  ")
    }

    /// A one-line diagnostic for a live remote slot: the nearest enrolled voice and
    /// its score (even below the accept threshold, so a near-miss is visible), or
    /// the audio still accumulating before the slot can be matched. `nil` for *you*
    /// or a slot the namer hasn't evaluated yet.
    func liveDebugLine(for label: SpeakerLabel) -> String? {
        guard let slot = label.remoteSlot, let diagnostics = liveDebug[slot] else { return nil }
        if diagnostics.samples < diagnostics.minSamples {
            return "slot \(slot)  gathering \(diagnostics.samples)/\(diagnostics.minSamples)"
        }
        guard let nearest = diagnostics.nearestName else { return "slot \(slot)  no match" }
        return String(format: "slot %d  nearest %@ %.2f", slot, nearest, diagnostics.score)
    }

    /// Load the enrolled voiceprint directory into ``voiceprintDirectory`` for the
    /// inspector, newest-named-looking duplicates included (people sharing a name
    /// surface as separate rows). Sorted by name then id for a stable list; a store
    /// failure leaves the previous list and is surfaced.
    func loadVoiceprintDirectory() {
        do {
            voiceprintDirectory = try voiceprintStore?.enrolledPersons()
                .sorted { ($0.person.name, $0.person.id.uuidString) < (
                    $1.person.name,
                    $1.person.id.uuidString
                ) }
                ?? []
        } catch {
            errorMessage = "load voiceprints: \(error)"
        }
    }

    /// Fold one enrolled person's voiceprints into another (collapsing a duplicate),
    /// then reload the directory so the inspector reflects the merge. A store failure
    /// is surfaced and leaves both people intact.
    func mergeVoiceprints(_ source: UUID, into destination: UUID) {
        do {
            try voiceprintStore?.merge(source, into: destination)
            loadVoiceprintDirectory()
        } catch {
            errorMessage = "merge voiceprints: \(error)"
        }
    }

    /// First 8 characters of a UUID — enough to tell two same-named people apart in
    /// the overlay without the full id's noise.
    static func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }
}
