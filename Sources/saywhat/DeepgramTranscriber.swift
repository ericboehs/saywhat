import Foundation
import SayWhatCore

/// A **reference** (cloud SOTA) transcriber, for the benchmark only — Deepgram's
/// hosted Nova-3 model with diarization.
///
/// This is a deliberate, isolated exception to SayWhat's on-device invariant: it
/// lives in the `saywhat` CLI target, which is **never** linked into the app, so
/// `SayWhatCore` and the app make no network calls (CLAUDE.md). It exists purely so
/// the on-device engines can be scored against a cloud baseline on the same
/// fixtures — `saywhat transcribe --engine deepgram` emits the same JSONL the
/// on-device path does, and `saywhat bench` compares the two.
///
/// Audio bytes are POSTed to Deepgram's pre-recorded API; the returned utterances
/// map straight onto a ``Transcript`` (every speaker is a `remote` slot — the
/// benchmark scores clusters, not identities). The API key is read from
/// `DEEPGRAM_API_KEY`, so the secret stays in the process and never touches disk.
struct DeepgramTranscriber {
    let apiKey: String
    var model = "nova-3"

    enum DeepgramError: Error, CustomStringConvertible {
        case missingKey
        case http(Int, String)
        case malformed(String)

        var description: String {
            switch self {
            case .missingKey:
                "DEEPGRAM_API_KEY is not set (try: DEEPGRAM_API_KEY=$(op read op://…/credential) …)"
            case let .http(code, body):
                "Deepgram HTTP \(code): \(body.prefix(300))"
            case let .malformed(detail):
                "Deepgram response was malformed: \(detail)"
            }
        }
    }

    /// Build from the environment, or throw a clear error if the key is absent.
    static func fromEnvironment() throws -> DeepgramTranscriber {
        guard let key = ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"],
              !key.isEmpty
        else { throw DeepgramError.missingKey }
        return DeepgramTranscriber(apiKey: key)
    }

    /// Transcribe a local audio file and return it as a finalized ``Transcript``.
    func transcribe(_ audio: URL) async throws -> Transcript {
        guard var components = URLComponents(string: "https://api.deepgram.com/v1/listen") else {
            throw DeepgramError.malformed("bad endpoint URL")
        }
        components.queryItems = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "diarize", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "utterances", value: "true"),
            URLQueryItem(name: "language", value: "en"),
        ]
        guard let url = components.url else {
            throw DeepgramError.malformed("could not build request URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.contentType(for: audio), forHTTPHeaderField: "Content-Type")

        let body = try Data(contentsOf: audio)
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else {
            throw DeepgramError.malformed("no HTTP response")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw DeepgramError.http(http.statusCode, String(bytes: data, encoding: .utf8) ?? "")
        }
        return try Self.transcript(from: data)
    }

    /// Map Deepgram's `results.utterances[]` onto a ``Transcript``. Each utterance's
    /// integer speaker becomes a `remote` slot; word timings carry through for
    /// playback/boundary scoring. The utterances array is present because the request
    /// sets `utterances=true`.
    static func transcript(from data: Data) throws -> Transcript {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response: Response
        do {
            response = try decoder.decode(Response.self, from: data)
        } catch {
            throw DeepgramError.malformed("\(error)")
        }
        let utterances = response.results.utterances ?? []
        return Transcript(utterances: utterances.enumerated().map { index, utterance in
            Transcript.Utterance(
                id: index,
                speaker: .remote(utterance.speaker ?? 0),
                text: utterance.transcript,
                range: .seconds(utterance.start) ..< .seconds(utterance.end),
                words: (utterance.words ?? []).map { word in
                    WordTiming(
                        text: word.punctuatedWord ?? word.word,
                        range: .seconds(word.start) ..< .seconds(word.end)
                    )
                }
            )
        })
    }

    /// A best-effort MIME type from the file extension; Deepgram also auto-detects.
    private static func contentType(for audio: URL) -> String {
        switch audio.pathExtension.lowercased() {
        case "wav": "audio/wav"
        case "m4a", "mp4", "aac": "audio/mp4"
        case "mp3": "audio/mpeg"
        case "flac": "audio/flac"
        default: "application/octet-stream"
        }
    }
}

/// The slice of Deepgram's pre-recorded response the benchmark consumes. Snake-case
/// keys (`punctuated_word`) are folded in via the decoder's key strategy.
private struct Response: Decodable {
    let results: Results

    struct Results: Decodable {
        let utterances: [Utterance]?
    }

    struct Utterance: Decodable {
        let start: Double
        let end: Double
        let transcript: String
        let speaker: Int?
        let words: [Word]?
    }

    struct Word: Decodable {
        let word: String
        let punctuatedWord: String?
        let start: Double
        let end: Double
    }
}
