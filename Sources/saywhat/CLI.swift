import Foundation
import SayWhatBench
import SayWhatCore

/// `saywhat` — a command-line frontend over the same core the app uses, for running
/// the pipeline over a file and scoring it against ground truth without the GUI loop.
///
/// It is a *sibling* of the app, not a backend it shells out to: both consume
/// `SayWhatCore` directly; this one just speaks JSONL instead of SwiftUI. Two
/// subcommands today:
///
///     saywhat transcribe <audio> [--out file.jsonl]
///         Import <audio>, run the on-device final pass (Parakeet + Sortformer),
///         and emit the authoritative transcript as JSONL.
///
///     saywhat bench <hypothesis.jsonl> <reference.jsonl> [--system name]
///         Score a hypothesis transcript against a ground-truth reference —
///         WER, DER + cluster consistency, boundary accuracy.
@main
enum CLI {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            usage()
            exit(2)
        }
        args.removeFirst()

        do {
            switch command {
            case "transcribe": try await transcribe(args)
            case "bench": try bench(args)
            case "-h", "--help", "help": usage()
            default:
                FileHandle.standardError.write(Data("unknown command: \(command)\n\n".utf8))
                usage()
                exit(2)
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    // MARK: transcribe

    /// Import an audio file as a session and run the on-device final pass over it,
    /// emitting the resulting transcript as JSONL. Speakers stay generic (`Speaker N`)
    /// — identity resolution needs a voiceprint store, which the benchmark doesn't
    /// want anyway (it scores clusters, not names).
    private static func transcribe(_ args: [String]) async throws {
        let options = Options(args)
        guard let audio = options.positional.first else {
            throw CLIError("transcribe needs an audio file path")
        }
        let source = URL(fileURLWithPath: audio)
        let engine = options.value("--engine") ?? "ondevice"

        let transcript: Transcript
        switch engine {
        case "ondevice": transcript = try await onDeviceTranscript(of: source)
        case "deepgram": transcript = try await deepgramTranscript(of: source)
        default:
            throw CLIError("unknown --engine \"\(engine)\"; use ondevice or deepgram")
        }

        let jsonl = TranscriptJSONL.encode(transcript)
        if let out = options.value("--out") {
            try jsonl.write(toFile: out, atomically: true, encoding: .utf8)
            progress("wrote \(transcript.utterances.count) utterances → \(out)")
        } else {
            print(jsonl, terminator: "")
        }
    }

    /// The on-device final pass (Parakeet + Sortformer) over an imported recording —
    /// the same core the app runs. Speakers stay generic `Speaker N` (no voiceprint
    /// store), which is exactly what the benchmark wants: it scores clusters.
    private static func onDeviceTranscript(of source: URL) async throws -> Transcript {
        let session = RecordingSession(directory: scratchSession())
        defer { try? FileManager.default.removeItem(at: session.directory) }

        progress("importing \(source.lastPathComponent)…")
        try await RecordingImporter()(source, into: session)

        let pass = FinalPass(
            diarizer: SortformerLiveDiarizer(),
            makeTranscriber: { ParakeetTranscriber(source: $0) }
        )
        return try await pass.run(session) { update in
            progress("\(update.phase)\(update.fraction.map { " \(Int($0 * 100))%" } ?? "")")
        }.transcript
    }

    /// The cloud SOTA reference (Deepgram Nova-3) over the same file — benchmark only,
    /// network, never the app. Key comes from `DEEPGRAM_API_KEY`. See
    /// ``DeepgramTranscriber``.
    private static func deepgramTranscript(of source: URL) async throws -> Transcript {
        let deepgram = try DeepgramTranscriber.fromEnvironment()
        progress("transcribing \(source.lastPathComponent) via Deepgram \(deepgram.model)…")
        return try await deepgram.transcribe(source)
    }

    // MARK: bench

    /// Score a hypothesis JSONL transcript against a reference JSONL transcript and
    /// print the three-axis report. Pure: no models, no audio — just the two files.
    private static func bench(_ args: [String]) throws {
        let options = Options(args)
        guard options.positional.count >= 2 else {
            throw CLIError("bench needs <hypothesis.jsonl> <reference.jsonl>")
        }
        let hypothesis = try TranscriptJSONL.decode(String(
            contentsOfFile: options.positional[0],
            encoding: .utf8
        ))
        let reference = try TranscriptJSONL.decode(String(
            contentsOfFile: options.positional[1],
            encoding: .utf8
        ))
        let report = BenchmarkReport(
            system: options.value("--system") ?? "hypothesis",
            hypothesis: hypothesis,
            reference: reference
        )
        print(report.summary())
    }

    // MARK: helpers

    private static func scratchSession() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("saywhat-cli-\(UUID().uuidString)", isDirectory: true)
    }

    private static func progress(_ message: String) {
        FileHandle.standardError.write(Data("\u{1B}[2K\r\(message)".utf8))
    }

    private static func usage() {
        print("""
        saywhat — on-device transcription pipeline, on the command line

        USAGE:
          saywhat transcribe <audio> [--engine ondevice|deepgram] [--out file.jsonl]
          saywhat bench <hypothesis.jsonl> <reference.jsonl> [--system name]

        ENGINES:
          ondevice  (default)  on-device final pass — Parakeet + Sortformer
          deepgram             cloud SOTA reference — needs DEEPGRAM_API_KEY
                               (benchmark only; never linked into the app)
        """)
    }
}

/// A surfaced, user-facing CLI error (bad arguments, missing file) — distinct from an
/// engine error, but printed the same way.
private struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) {
        self.description = description
    }
}

/// Dirt-simple argument split: bare words are positionals, `--flag value` pairs are
/// options. Enough for a dev tool; no need for a parsing dependency.
private struct Options {
    private(set) var positional: [String] = []
    private var flags: [String: String] = [:]

    init(_ args: [String]) {
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg.hasPrefix("--"), index + 1 < args.count {
                flags[arg] = args[index + 1]
                index += 2
            } else {
                positional.append(arg)
                index += 1
            }
        }
    }

    func value(_ flag: String) -> String? {
        flags[flag]
    }
}
