import Foundation
import Testing
@testable import SayWhatCore

@Suite("TranscriptStore")
struct TranscriptStoreTests {
    /// A throwaway directory that cleans itself up.
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("saywhat-transcript-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sampleDocument() -> SessionTranscript {
        let transcript = Transcript(utterances: [
            Transcript.Utterance(
                id: 0,
                speaker: .you,
                speakerName: nil,
                text: "Mic check.",
                range: .seconds(0) ..< .seconds(2),
                words: [WordTiming(text: "Mic", range: .seconds(0) ..< .seconds(1))]
            ),
            Transcript.Utterance(
                id: 1,
                speaker: .remote(0),
                speakerName: "Zwag",
                text: "Hello there.",
                range: .seconds(2) ..< .seconds(4)
            ),
        ])
        let person = Person(name: "Zwag")
        let exemplar = Voiceprint(personID: person.id, embedding: [0.1, 0.2, 0.3])
        return SessionTranscript(
            transcript: transcript,
            speakers: [0: ResolvedSpeaker(person: person, exemplar: exemplar, name: "Zwag")],
            utteranceVoiceprints: [1: Voiceprint(embedding: [0.4, 0.5, 0.6])]
        )
    }

    @Test("a saved document round-trips byte-for-byte through reload")
    func roundTrips() throws {
        let store = TranscriptStore(directory: tempDir())
        let document = sampleDocument()

        #expect(store.exists == false)
        try store.save(document)
        #expect(store.exists == true)

        let loaded = try store.load()
        #expect(loaded == document)
    }

    @Test("loading before any save returns nil, not an error")
    func loadMissingIsNil() throws {
        let store = TranscriptStore(directory: tempDir())
        #expect(try store.load() == nil)
    }

    @Test("saving twice overwrites the prior document")
    func saveOverwrites() throws {
        let store = TranscriptStore(directory: tempDir())
        try store.save(sampleDocument())

        var edited = sampleDocument()
        edited.transcript = Transcript(utterances: [])
        try store.save(edited)

        #expect(try store.load()?.transcript.isEmpty == true)
    }
}
