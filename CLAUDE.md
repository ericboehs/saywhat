# CLAUDE.md

Guidance for Claude Code working in this repo.

## What this is

**SayWhat** — an on-device meeting recorder, real-time transcriber, speaker
diarizer, and summarizer for Apple Silicon Macs. Everything runs locally; no
cloud, no accounts, no audio leaves the machine. Native macOS app, Swift 6 +
SwiftUI, macOS 26 (Tahoe) minimum, Apple Silicon only.

**Read [DESIGN.md](DESIGN.md) first** — it is the source of truth for
architecture, scope, and the rationale behind every major decision. This file is
just the working orientation. **Read [QUALITY.md](QUALITY.md)** for the quality
bar / definition-of-done that every change must meet.

## The one-paragraph architecture

Two audio tracks (mic via `AVAudioEngine`, system via `ScreenCaptureKit`) are
kept **separate end to end** — this is the most important invariant in the
codebase; never mix them into one stream (it collapses diarization). A **live
pipeline** (Apple `SpeechTranscriber` + FluidAudio Sortformer) drives the
readable real-time transcript. A **final pipeline** (FluidAudio Parakeet TDT v3
batch + offline pyannote + persistent speaker-ID) runs at meeting end over
continuously-saved AAC to produce the authoritative transcript, which feeds a
**`Summarizer`** (Apple Foundation Models or MLX, user-selectable). The live ML
runs on the **Neural Engine**, not the GPU.

## Hard invariants (don't break these)

- **Mic and system audio stay separate** — separate capture, separate storage,
  separate transcriber instances. The channel is free coarse diarization.
- **On-device only.** No network calls except first-run model download and
  optional calendar lookup. No telemetry. No transcript/audio ever uploaded.
  (A cloud `Summarizer` is a deliberate, documented escape hatch — not the
  default, not in v1.)
- **Every engine is behind a protocol** (`Transcriber`, `Diarizer`,
  `Summarizer`). Swappable by design. Don't hardcode a model into the UI or
  pipeline.
- **Audio is durable.** Continuous streaming encode to disk; a transcription or
  LLM crash must never lose the recording or take down capture.
- **Echo cancellation is opt-in, never default-on**, and must never seize the
  system input device (it broke Teams calls in the comparable app, Trace).

## Tech stack quick reference

| Layer | What | Behind protocol |
|---|---|---|
| Capture | `AVAudioEngine` (mic) + `ScreenCaptureKit` (system) → 16 kHz mono Float32 + AAC | — |
| Live ASR | Apple `SpeechTranscriber` (volatile→final) | `Transcriber` |
| Batch ASR | FluidAudio Parakeet TDT v3 | `Transcriber` |
| Diarization | FluidAudio Sortformer (live) + offline pyannote (final) | `Diarizer` |
| Speaker ID | FluidAudio `SpeakerManager` + local voiceprint DB | — |
| Summary | Apple Foundation Models (map-reduce, 4096 ctx) / MLX `mlx-swift-lm` (Gemma/Qwen, 1-pass) | `Summarizer` |
| Storage | SQLite (GRDB) + AAC/m4a 32 kbps; retention by days or GB | — |

## Dependencies (SPM)

- **FluidAudio** — github.com/FluidInference/FluidAudio (Apache-2.0; Sortformer
  model is NVIDIA Open Model License — note for commercial use).
- **mlx-swift-lm** — `MLXLLM` + `MLXLMCommon` (import **both**, or you hit
  `noModelFactoryAvailable`).
- **GRDB** — SQLite.
- Apple frameworks: `Speech` (SpeechAnalyzer/SpeechTranscriber),
  `FoundationModels`, `ScreenCaptureKit`, `AVFoundation`, `SwiftUI`.

## Build & test

> The app target lives in a committed **vanilla** `SayWhat.xcodeproj` (no
> generator). Xcode's filesystem-synchronized groups keep file add/remove out of
> `project.pbxproj`, so merge conflicts are rare; build settings live as text in
> `Config/SayWhat.xcconfig`. See QUALITY.md "Project gen".

```bash
# Build & test the pure core (SPM)
swift build
swift test --enable-code-coverage

# Build the macOS app target (needs Xcode: Info.plist, entitlements, .app bundle)
xcodebuild build -project SayWhat.xcodeproj -scheme SayWhat \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO

# Lint / format (see QUALITY.md for the canonical config)
swift format lint --recursive Sources Tests   # Apple swift-format
swiftlint                                       # SwiftLint

# Dead code
periphery scan
```

⚠️ **MLX needs Xcode for Metal shaders** — `swift build` from the CLI alone
can't compile MLX's Metal kernels. Build/run the app target in Xcode (or
`xcodebuild`) when exercising the MLX summarizer.

## Repo layout (intended)

```
App/                 # app target (SwiftUI) — built by the committed SayWhat.xcodeproj
Config/              # SayWhat.xcconfig + entitlements (build settings as text)
Sources/
  SayWhatCore/       # the pure, SPM-testable core (the engine subdirs below live here)
  Capture/           # AVAudioEngine + ScreenCaptureKit, dual-track, AAC encode
                     #   Adapters/ — hardware-touching impls (coverage-excluded)
  Transcription/     # Transcriber protocol + Apple/Parakeet/WhisperKit impls
  Diarization/       # Diarizer protocol + Sortformer/pyannote + SpeakerManager
  Summarization/     # Summarizer protocol + AppleFM/MLX impls + map-reduce
  Storage/           # GRDB models, retention policy
  Models/            # shared value types (TranscriptSegment, MeetingNotes, …)
Tests/
  …                  # Swift Testing; golden-file fixtures for ASR/diarization
DESIGN.md  QUALITY.md  CLAUDE.md
```

(Some SwiftUI views/models are carried from the earl-scribe viewer — see below.)

## Prior art to mine (not depend on)

`~/Code/ericboehs/earl-scribe` — the predecessor prototype. Reuse:

- **SwiftUI viewer** (`macos/EarlScribe/EarlScribe/`): `MenuBarView`,
  `SidebarView`, `TranscriptView`, `SessionDetailView`, the `AppState` +
  view-model split, markdown/transcript rendering. Replace its file-watching /
  CLI-spawning services with in-process capture + engine services.
- **Benchmark harness** (`test/fixtures/benchmark/`): a 60 s 2-speaker clip with
  ground truth, scored on WER + diarization cluster consistency + ±500 ms
  boundary accuracy. Carry this forward.
- Its on-device Swift ASR engine source was **lost** (only a compiled binary
  remains) — that's *why* SayWhat is a fresh build, not a fork.

## Conventions

- **Conventional commits.** Never `git commit --no-verify`. Don't commit or push
  unless asked.
- **Swift 6 strict concurrency** on; warnings-as-errors. Respect actor
  isolation, especially across the capture/engine boundary.
- **Swift Testing** (`@Test` / `#expect`) for new tests; XCTest only where
  required (UI automation, performance).
- ML/audio layers are tested via **golden-file fixtures** and accuracy
  regression (WER / DER), not brittle mocks of the models themselves.
- Match surrounding style; keep engines swappable; don't leak a concrete model
  type past its protocol.

## Status

**Phase 0 (capture & durability) complete.** Docs + tooling/CI, the capture
domain model + crash-safe durability core, both capture adapters (`AVAudioEngine`
mic + `ScreenCaptureKit` system audio), the `AVAssetWriter`-backed durable AAC
writer with rotating segments + crash recovery, a live input-level meter, and a
minimal SwiftUI app target (committed vanilla `SayWhat.xcodeproj`) have landed. A
Record press now produces a recoverable, **dual-track** recording on disk —
verified end to end. Local dev builds are signed with a self-signed cert (wired
via a gitignored `Config/Local.xcconfig`) so the App Sandbox is enforced and
recordings land in the app container; see `Config/Local.xcconfig.example`.

**Phase 1 (live transcript) is next** — the `Transcriber` protocol + Apple
`SpeechTranscriber` per track, volatile→final, on screen. See
[CHANGELOG.md](CHANGELOG.md) for what's shipped and DESIGN.md §14 for the build
order.
