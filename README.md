# SayWhat

**On-device meeting recorder, real-time transcriber, speaker diarizer, and
summarizer for Apple Silicon Macs.** Everything runs locally — no cloud, no
accounts, no audio ever leaves your machine.

> Status: **pre-implementation.** The architecture and quality bar are locked
> (see below); code starts at Phase 0. This is an open-source project built in
> the open.

## What it does

- 🎙️ **Records meetings** — your mic *and* the other participants' audio
  (Teams / Zoom / Meet) via ScreenCaptureKit, or a room mic for in-person.
- ⚡ **Real-time transcript you can read** while the meeting happens, powered by
  Apple's on-device `SpeechTranscriber`.
- 🗣️ **Speaker diarization with persistent identity** — "Eric" and "Ashley" are
  recognized across meetings via voiceprint enrollment, not just relabeled every
  session.
- 📝 **On-device summaries** — action items, decisions, and a recap, produced by
  a local LLM you choose (small/fast now, large/high-quality on better hardware).
- 🔒 **Fully private** — the only network call is the first-run model download.

## Why it's fast (and cool, and quiet)

The live pipeline runs on the **Neural Engine**, not the GPU. Apple
SpeechTranscriber and [FluidAudio](https://github.com/FluidInference/FluidAudio)
(Parakeet, Sortformer, Silero VAD) are ANE/CoreML and deliberately avoid
GPU/Metal. So during a meeting your GPU is idle, the machine stays cool and
battery-friendly, and the only GPU burst is the one-shot summary at the end.

## Architecture

```
 mic ──AVAudioEngine─┐
                     ├─►[mic track] ─► SpeechTranscriber ─► live transcript ─┐
 system─ScreenCapture┘  [sys track] ─► SpeechTranscriber ─► (Sortformer) ────┤
   Kit                                                                       │
        │                                                          SwiftUI live view
        └─ both tracks → continuous AAC to disk (crash-safe) ─┐
                                                              ▼
              final pass: Parakeet TDT v3 (batch) + pyannote diarization
                          + persistent speaker ID  ─►  Summarizer
                                                       (Apple FM / MLX)
```

Two audio tracks are kept **separate end to end** — that channel split is the
single biggest accuracy lever for diarization. A **live pipeline** drives the
readable transcript; a **final pass** re-transcribes the saved audio at higher
accuracy and produces the canonical transcript + summary. Every engine sits
behind a protocol (`Transcriber`, `Diarizer`, `Summarizer`) so models are
swappable.

**Full details:** [DESIGN.md](DESIGN.md).

## Tech stack

| Layer | Tech |
|---|---|
| Platform | macOS 26 (Tahoe), Apple Silicon, Swift 6 + SwiftUI |
| Capture | `AVAudioEngine` (mic) + `ScreenCaptureKit` (system) |
| Live ASR | Apple `SpeechTranscriber` |
| Batch ASR | FluidAudio Parakeet TDT v3 |
| Diarization | FluidAudio Sortformer (live) + offline pyannote (final) |
| Speaker ID | FluidAudio `SpeakerManager` + local voiceprint DB |
| Summary | Apple Foundation Models / MLX (`mlx-swift-lm`) — user-selectable |
| Storage | SQLite (GRDB) + AAC/m4a 32 kbps, retention by days or GB |

## Choosing a summarizer

Summarization is a config choice — it runs once, at the end, on transcript text:

| Tier | Model | ~RAM (4-bit) | Notes |
|---|---|---|---|
| Zero-setup | Apple Foundation Models | — (in OS) | No download; 4096-token context → map-reduce. |
| Default | Gemma 4 E4B / Gemma 3n E4B | ~4 GB | Small, fast, one-pass. Good on an M2 Max. |
| Quality | Qwen3-30B-A3B-Instruct-2507 | ~17 GB | MoE (~3B active); near-cloud quality on M5 Max / 64 GB. |

## Building

```bash
git clone https://github.com/ericboehs/saywhat
cd saywhat
swift build
swift test --enable-code-coverage
```

⚠️ The MLX summarizer needs **Xcode** to compile Metal shaders — build/run the
app target in Xcode when exercising it. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Contributing

PRs welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) and [QUALITY.md](QUALITY.md)
first — SayWhat holds a strict, CI-enforced quality bar (Swift 6 strict
concurrency, Swift Testing, ≥80% patch coverage, CodeQL, golden-file ML tests).

## Acknowledgements

- [FluidAudio](https://github.com/FluidInference/FluidAudio) — the on-device ASR
  + diarization backbone (Apache-2.0; the Sortformer model carries NVIDIA's Open
  Model License).
- Apple's SpeechAnalyzer / Foundation Models frameworks (macOS 26).
- Hard-won lessons from [Trace](https://news.ycombinator.com/item?id=48521236)
  and the predecessor prototype `earl-scribe`.

## License

[MIT](LICENSE).
