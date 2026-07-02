import Foundation
import SayWhatBench
import SayWhatCore

/// `saywhat` — a command-line frontend over the same core the app uses, for running
/// the pipeline over a file and scoring it against ground truth without the GUI loop.
///
/// It is a *sibling* of the app, not a backend it shells out to: both consume
/// `SayWhatCore` directly; this one just speaks JSONL instead of SwiftUI. Three
/// subcommands today:
///
///     saywhat transcribe <audio> [--out file.jsonl]
///         Import <audio>, run the on-device final pass (Parakeet + Sortformer),
///         and emit the authoritative transcript as JSONL.
///
///     saywhat bench <hypothesis.jsonl> <reference.jsonl> [--system name]
///         Score a hypothesis transcript against a ground-truth reference —
///         WER, DER + cluster consistency, boundary accuracy.
///
///     saywhat brief <transcript.jsonl | session-dir> [--floor words]
///         Replay a finalized transcript through the live-brief fold as if the
///         meeting were live, printing each pass — the L1 tuning spike.
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
            case "brief": try await brief(args)
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

        // Opt-in onset-boundary refinement (prototype): snap diarizer turn edges to
        // the ASR's word/silence structure. Enable with SAYWHAT_REFINE_ONSETS=1.
        let refiner = ProcessInfo.processInfo.environment["SAYWHAT_REFINE_ONSETS"] != nil
            ? OnsetRefiner()
            : nil
        let pass = FinalPass(
            diarizer: SortformerLiveDiarizer(),
            onsetRefiner: refiner,
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

    // MARK: brief

    /// The Phase-L1 replay spike (docs/live-intelligence.md): replay a finalized
    /// transcript through the live-brief fold as if the meeting were happening
    /// now, printing the brief after every pass. This is the harness for tuning
    /// prompt, schema, and cadence against real recordings, cheaply and
    /// reproducibly, without the GUI loop.
    private static func brief(_ args: [String]) async throws {
        let options = Options(args)
        guard let path = options.positional.first else {
            throw CLIError(
                "brief needs a transcript: a .jsonl from `saywhat transcribe`, or a session directory"
            )
        }
        let transcript = try loadTranscript(path)
        guard !transcript.isEmpty else { throw CLIError("transcript is empty") }
        let floor = options.value("--floor").flatMap { Int($0) } ?? 80

        let fold = LiveBriefFold(analyst: FoundationModelsAnalystAdapter(), wordFloor: floor)
        var printed = 0
        for utterance in transcript.utterances {
            await fold.ingest(LiveBriefFold.Segment(
                speaker: utterance.speakerName ?? genericName(utterance.speaker),
                text: utterance.text,
                time: utterance.start
            ))
            printed = await report(fold, after: printed)
        }
        await fold.finish()
        printed = await report(fold, after: printed)
        if printed == 0 {
            if let error = await fold.lastError {
                progress("no brief produced — every pass failed. Last: \(error)\n")
            } else {
                progress(
                    "no fold pass ran — transcript shorter than the --floor of \(floor) words?\n"
                )
            }
        }
    }

    /// Print the brief when a new pass completed since `printed`; surface a
    /// skipped (failed) pass on stderr. Returns the new pass count.
    private static func report(_ fold: LiveBriefFold, after printed: Int) async -> Int {
        if let error = await fold.lastError {
            progress("pass skipped: \(error)\n")
        }
        let passes = await fold.passes
        guard passes > printed else { return printed }
        let state = await fold.snapshot()
        print("\n━━ pass \(passes) ━━")
        for (title, items) in [
            ("NEXT STEPS", state.nextSteps),
            ("OPEN QUESTIONS", state.openQuestions),
            ("SUGGESTED QUESTIONS", state.suggestedQuestions),
        ] {
            print(title)
            if items.isEmpty { print("  (none)") }
            for item in items {
                var line = "  [\(LiveBriefFold.timecode(item.at))] \(item.text)"
                if let speaker = item.speaker { line += " — \(speaker)" }
                if item.resolved { line += " ✓resolved" }
                print(line)
            }
        }
        return passes
    }

    /// A transcript from either a `.jsonl` file (the CLI's native format) or a
    /// session directory holding the app's saved `transcript.json`.
    private static func loadTranscript(_ path: String) throws -> Transcript {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw CLIError("no such file: \(path)")
        }
        if isDirectory.boolValue {
            let store = TranscriptStore(directory: URL(fileURLWithPath: path, isDirectory: true))
            guard let document = try store.load() else {
                throw CLIError("no saved transcript in \(path)")
            }
            return document.transcript
        }
        return try TranscriptJSONL.decode(String(contentsOfFile: path, encoding: .utf8))
    }

    /// The label the live view would have shown: remote slots are 0-based on the
    /// wire, 1-based on screen.
    private static func genericName(_ label: SpeakerLabel) -> String {
        switch label {
        case .you: "You"
        case let .remote(slot): "Speaker \(slot + 1)"
        }
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
          saywhat brief <transcript.jsonl | session-dir> [--floor words]
              Replay a finalized transcript through the live-brief fold (Apple
              Foundation Models) as if the meeting were live, printing the brief
              after every pass — the docs/live-intelligence.md L1 spike.

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
