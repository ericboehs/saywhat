import Foundation
import SayWhatCore

/// The transcript-editing and history-library half of ``CaptureModel``: naming
/// speakers, correcting a single mis-grouped segment, persisting the curated
/// transcript, and listing/reopening past recordings. Split into its own file so
/// the model's main declaration stays focused on the live capture/recording
/// lifecycle; it writes the model's module-internal editable-session state.
extension CaptureModel {
    /// Name the remote speaker in `slot`, binding this meeting's exemplar of their
    /// voice to a ``Person`` (an existing one if the name already exists, else a
    /// new one) so every future meeting recognizes that voice — and relabel the
    /// speaker's turns in the transcript on screen now. A blank name, an unknown
    /// slot (no resolved speaker), or a storage failure is a no-op (the latter
    /// surfaced).
    func renameSpeaker(slot: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let resolved = speakers[slot] else { return }
        guard let person = bindVoice(resolved.exemplar, to: trimmed) else { return }
        speakers[slot] = ResolvedSpeaker(person: person, exemplar: resolved.exemplar, name: trimmed)
        finalTranscript = finalTranscript?.renamingSpeaker(slot, to: trimmed).coalesced()
        persist()
    }

    /// Reassign a **single** utterance to `name`, correcting one segment the
    /// diarizer mis-grouped without touching the rest of its group. Binds that
    /// segment's *own* voice to the person (so future meetings recognize it even
    /// though the group resolved to someone else), relabels just this utterance —
    /// adopting that person's color if they appear elsewhere — and persists. A
    /// blank name or storage failure is a no-op (the latter surfaced).
    func reassignUtterance(id: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Teach the person this segment's voice when we have its embedding; a
        // segment too short to embed still relabels, just without learning.
        if let voiceprint = utteranceVoiceprints[id], bindVoice(voiceprint, to: trimmed) == nil {
            return
        }
        finalTranscript = finalTranscript?.reassigningUtterance(id, to: trimmed).coalesced()
        persist()
    }

    /// Resolve `name` to a ``Person`` (existing or freshly created) and bind
    /// `exemplar` to them in the voiceprint store, so the voice is recognized in
    /// future meetings. Returns the person, or `nil` when no store is wired or the
    /// write fails (surfaced).
    private func bindVoice(_ exemplar: Voiceprint, to name: String) -> Person? {
        guard let store = voiceprintStore else { return nil }
        do {
            let person = try store.person(named: name) ?? {
                let created = Person(name: name)
                try store.savePerson(created)
                return created
            }()
            var bound = exemplar
            bound.personID = person.id
            try store.save(bound)
            return person
        } catch {
            errorMessage = "bind speaker: \(error)"
            return nil
        }
    }

    /// Save the current authoritative transcript beside its audio, so hand-curated
    /// labels survive reopening. A write failure is surfaced but never disturbs the
    /// on-screen transcript or the durable recording.
    func persist() {
        guard let transcriptStore, let finalTranscript else { return }
        do {
            try transcriptStore.save(SessionTranscript(
                transcript: finalTranscript,
                speakers: speakers,
                utteranceVoiceprints: utteranceVoiceprints
            ))
        } catch {
            errorMessage = "save transcript: \(error)"
        }
    }

    /// Reload the list of past recordings from disk, newest first. Cheap directory
    /// enumeration; call on launch and whenever a recording finalizes.
    func refreshSessions() {
        sessions = SessionLibrary.sessions(in: Self.recordingsRoot())
    }

    /// Move a past recording to the Trash and drop it from the sidebar. Reversible
    /// by design — the user can restore it from the Trash — so it needs no
    /// destructive confirmation. The recording in progress is never deletable. If
    /// the removed session was on screen, the detail pane clears. A failure is
    /// surfaced and the list is left intact.
    func deleteSession(id: String) {
        guard !(isRecording && id == selectedSessionID),
              let session = sessions.first(where: { $0.id == id }) else { return }
        do {
            try FileManager.default.trashItem(at: session.directory, resultingItemURL: nil)
        } catch {
            errorMessage = "move recording to Trash: \(error)"
            return
        }
        if selectedSessionID == id {
            selectedSessionID = nil
            sessionPath = nil
            finalTranscript = nil
            speakers = [:]
            utteranceVoiceprints = [:]
            transcriptStore = nil
            playback?.pause()
            playback = nil
        }
        refreshSessions()
    }

    /// Reopen a past session for viewing and editing: load its saved transcript
    /// (speakers and per-utterance voiceprints included, so renames and per-segment
    /// reassignment keep working) and play its audio. Ignored while a recording is
    /// in progress, so reopening can never disturb a live capture. A session with no
    /// saved `transcript.json` still opens for playback — the transcript is cleared.
    func openSession(id: String) {
        guard !isRecording, let session = sessions.first(where: { $0.id == id }) else { return }
        selectedSessionID = id
        sessionPath = session.directory.path
        finalizeStatus = nil
        errorMessage = nil

        let store = TranscriptStore(directory: session.directory)
        transcriptStore = store
        let document = try? store.load()
        // Normalize on load too, so a transcript saved before coalescing (or hand-
        // edited elsewhere) still honors the one-block-per-adjacent-speaker invariant.
        finalTranscript = document?.transcript.coalesced()
        speakers = document?.speakers ?? [:]
        utteranceVoiceprints = document?.utteranceVoiceprints ?? [:]

        playback?.pause()
        playback = nil
        let controller = PlaybackController()
        Task {
            await controller.load(session: RecordingSession(directory: session.directory))
            if controller.isReady { playback = controller }
        }
    }
}
