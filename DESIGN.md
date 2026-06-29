# SayWhat — Design

> On-device meeting recorder, real-time transcriber, speaker diarizer, and
> summarizer for Apple Silicon Macs. Everything runs locally. No cloud, no
> accounts, no audio ever leaves the machine.

**Status:** Pre-implementation design. This document is the source of truth for
architecture and scope. It will change as we build; treat divergence between
code and this doc as a bug in one of them.

---

## 1. Goals & non-goals

### Goals

- **Real-time transcript you can read while the meeting happens.** Low-latency
  live captions are the headline feature, not an afterthought.
- **Fully on-device.** Transcription, diarization, and summarization all run
  locally on Apple Silicon. The only network call in the whole app is the
  first-run model download (and an optional calendar lookup for auto-titling).
- **Speaker diarization with persistent identity.** "Eric" and "Ashley" are
  recognized across meetings via voiceprint enrollment, not just relabeled
  "Speaker 1 / Speaker 2" every session.
- **High-accuracy final transcript.** A live pass for reading + a batch re-pass
  on saved audio for the authoritative record.
- **On-device summaries** with a user-selectable model (small/fast now, large/
  high-quality on better hardware).
- **Open source.** Clean, modular, documented, well-tested. Built so others can
  run it, contribute, and learn from it.

### Non-goals (for v1)

- **Cloud/SaaS anything.** No hosted transcription, no accounts, no telemetry.
- **Cross-platform.** macOS only. (The ML layers happen to work on iOS via
  FluidAudio, but we are not building an iOS app.)
- **Built-in "AI chat with your meeting" / RAG.** Tempting, deferred. v1 emits a
  clean transcript + summary; piping to an LLM chat is a later feature.
- **Real-time translation / multi-language UI.** English-first. The ASR stack
  supports more languages; the product is tuned for English meetings first.
- **Intel Mac support.** Apple Silicon only.

### Design tenets

1. **The live pipeline runs on the Neural Engine, not the GPU.** Apple
   SpeechTranscriber and FluidAudio (Parakeet, Sortformer, Silero VAD) are
   ANE/CoreML and explicitly avoid GPU/Metal. The GPU is idle during the
   meeting; it only does work for the one-shot summary at the end. This keeps
   the continuous part cool, quiet, and battery-friendly.
2. **Two audio tracks, never one mixed stream.** Mic and system audio are kept
   separate end to end. This is the single biggest accuracy lever in the system
   (see §4).
3. **Every engine is behind a protocol.** ASR, diarization, and summarization
   are swappable. We will change our minds about models; the architecture
   shouldn't care.
4. **Crash recovery is a first-class concern, not a bug fix.** Audio is
   streamed to disk continuously so a crash never loses a recording.

---

## 2. Platform & stack

| Concern | Choice | Notes |
|---|---|---|
| Min OS | **macOS 26 (Tahoe)** | Unlocks SpeechAnalyzer/SpeechTranscriber + Foundation Models. Apple Silicon only. |
| Language | **Swift 6** | Strict concurrency on. |
| UI | **SwiftUI** | Menu-bar app + main window. |
| Packaging | **Swift Package Manager** | SPM-first; project generated (Tuist/XcodeGen) to avoid `.xcodeproj` merge conflicts. See QUALITY.md. |
| Live ASR | **Apple `SpeechTranscriber`** | Streaming, volatile→final, zero binary bloat, ~70× realtime. |
| Batch ASR | **FluidAudio Parakeet TDT v3** | ~11–12% WER, 200×+ realtime, for the authoritative final pass. |
| Diarization | **FluidAudio** Sortformer (live + final), `wespeaker_v2` voiceprints | Apple does no diarization; FluidAudio is mandatory. |
| Speaker ID | **FluidAudio `SpeakerManager`** + local voiceprint DB | Persistent cross-session identity. |
| VAD | **FluidAudio Silero VAD** | Endpointing / silence gating. |
| Summary (default) | **Apple Foundation Models** | Zero download, on-device, 4096-token context → map-reduce. |
| Summary (quality) | **MLX via `mlx-swift-lm`** | In-process, user-selectable model (Gemma now → Qwen3 later). |
| Storage | **SQLite (GRDB)** + **AAC/m4a 32 kbps** audio | Retention policy by days or GB. |

**Why Swift / why native.** Given macOS-26-only + on-device + real-time, every
layer we need is now a native Swift framework. There is no subprocess, no Python
runtime, no local HTTP server, no JSONL-tailing IPC. One app, in-process. Python
would only fight us on real-time audio capture and on shipping a clean binary.

---

## 3. High-level architecture

```
                    ┌─────────── LIVE (real-time, what you read) ───────────┐
 mic ──AVAudioEngine─┐                                                       │
                     ├─►[mic track]─► VAD ─► SpeechTranscriber ─►volatile→final ─┐
 system─ScreenCapture┘  [sys track]─► VAD ─► SpeechTranscriber ─►volatile→final ─┤
   Kit                                 └─► Sortformer (live speaker labels) ─────┘ │
                                                                  merge by timestamp │
                                                                                    ▼
                                                                          SwiftUI live transcript
        │
        └─ both tracks streamed to disk as AAC continuously (crash recovery) ─┐
                                                                              ▼
                    ┌─────────── FINAL (on meeting end, authoritative) ───────────┐
                    │ Parakeet TDT v3 (batch ASR) + Sortformer (batch diarization) │
                    │      └─► SpeakerManager: match embeddings → "Eric","Ashley"  │
                    │                              ▼                               │
                    │                     Summarizer (protocol)                    │
                    │              ┌──────────────┴───────────────┐               │
                    │       Apple Foundation Models          MLX (Gemma/Qwen)     │
                    │       (4096 ctx → map-reduce)          (32K–256K → 1 pass)   │
                    └──────────────────────────────────────────────────────────┘
```

Two pipelines share the same captured audio:

- **Live pipeline** — optimized for latency. Drives the on-screen transcript.
  Results are "good enough to read," not authoritative.
- **Final pipeline** — runs when the meeting ends (or on demand). Re-transcribes
  the saved audio with the higher-accuracy batch model, runs offline diarization
  for the best speaker boundaries, resolves persistent speaker identities, and
  produces the canonical transcript + summary.

---

## 4. Audio capture (the foundation)

**Two tracks, kept separate end to end.** This is the most important decision in
the whole app.

- **Mic** via `AVAudioEngine` → the local speaker (you).
- **System audio** via `ScreenCaptureKit` → everyone else (Teams / Zoom / Meet
  output), or room audio for in-person.

Both are converted to **16 kHz mono Float32** (what every ASR/diarization model
expects) for the live pipeline, and simultaneously encoded to **AAC/m4a** for
storage.

### Why separate tracks

The channel itself is free, perfect coarse diarization: mic = you, system =
remote. Diarization then only has to split the *multiple remote speakers within
the system track* — it never has to untangle your voice from theirs out of one
mixed blob. Mixing mic + system into one stream is exactly what collapses
everyone onto "Speaker 0" (a hard-won lesson from the earl-scribe prototype, and
echoed all over the Trace discussion).

### Capture modes (user-selectable per session)

- **Video call** — mic + system audio, two tracks. The default.
- **In-person** — mic only (one device capturing the room); diarization splits
  voices from the single track. System track absent.

### Echo cancellation — handle with extreme care

Trace's worst real-world bug: aggressive acoustic echo cancellation **hijacked
the microphone and broke users' Teams calls** (other participants couldn't hear
them). Rules for us:

- AEC is **opt-in, never default-on**.
- Prefer the structural fix: **headphones** + treat the **system track** as the
  authoritative source for remote audio, so mic bleed of remote voices is
  ignored rather than cancelled.
- If we ever enable AEC, it must never reconfigure or seize the system default
  input device out from under an active call.

### Permissions

- Microphone (TCC).
- Screen Recording (ScreenCaptureKit, required even for audio-only system
  capture).
- App is **not sandboxed** if we need broad capture + helper behavior; revisit
  whether a sandboxed + entitlements path is viable for an eventual notarized
  release. (earl-scribe disabled the sandbox.)

---

## 5. Live transcription

**Engine:** Apple `SpeechTranscriber` (one instance per track).

- Feed audio buffers as an `AsyncSequence`; consume results as an
  `AsyncSequence` of `AttributedString` segments carrying per-token
  `audioTimeRange` + confidence + an `isFinal` flag.
- `reportingOptions: [.volatileResults]` → fast partial guesses for snappy UI;
  replace volatile text in place, commit on `isFinal`.
- `attributeOptions: [.audioTimeRange]` → word timings for live highlighting and
  for merging with diarization.
- The old `SFSpeechRecognizer` 1-minute limit is **gone** — this model is built
  for long-form, multi-hour, far-field, conversational audio.
- Model is a shared OS asset (downloaded once via `AssetInventory`,
  auto-updated, runs outside our address space — no binary bloat, no app-memory
  cost).

**Known gap:** SpeechTranscriber has **no custom vocabulary / phrase boosting.**
Jargon, acronyms, product and people names will be missed (e.g. VA/EERT terms).
Mitigations, in order of effort: (a) post-correct with the on-device LLM using a
user-maintained "meeting vocabulary" list; (b) use Parakeet's CTC vocab boosting
in the final pass; (c) WhisperKit prompt-biasing as an optional engine. v1 ships
(a) as a stretch goal; the protocol leaves room for all three.

**ASR is behind a protocol** (`Transcriber`) so Parakeet streaming or WhisperKit
can be swapped in per-context without touching the UI.

### Live echo handling — mono-mix for display only

A speaker's voice leaks from the laptop speakers into the mic, so running a
recognizer per track makes the **same remote utterance transcribe twice** —
once clean off the system track, once as echo off the mic. We tried two ways to
fix this on the mic side and rejected both: acoustic echo cancellation
(`setVoiceProcessingEnabled`) ducks system output, fails to pull mic audio
unless the engine also renders output, and risks seizing the input device — the
exact §4 hazard; and transcript-level dedupe (drop a mic line that fuzzy-matches
a recent system line) flickers visibly — text appears, then retracts.

What ships instead: for the **live transcript only**, sum the two 16 kHz tracks
into one mono stream (`AudioMixer`) and run **one** recognizer over it. The echo
and its source are the same sound at nearly the same time, so one recognizer
hears one utterance — no dedupe heuristic, nothing ever retracted on screen.

This does **not** violate the separate-tracks invariant (§4): capture and
**storage stay fully dual-track**, so the final pass still diarizes off clean
per-channel audio. Only the live *display* is mixed. The cost is no live speaker
separation (low value in a 5–10 person call — you know what you said, and the
final pass attributes the rest) and some accuracy loss on simultaneous
double-talk. Real reference-based AEC (mic minus the system track as echo
reference, e.g. SpeexDSP MDF) is the future *offline* path, behind an
`EchoCanceller` protocol over the saved AAC — see §7.

---

## 6. Diarization & speaker identity

Apple provides **no** diarization, so FluidAudio does it regardless of ASR
choice.

- **Live labels:** Sortformer (streaming, ~480 ms updates, up to 4 speakers).
  Runs concurrently with ASR and tags each utterance with a speaker id. Good
  enough for live "who's talking" coloring.
- **Final boundaries:** Sortformer re-run as a single batch over the saved audio
  during the final pass. On real meeting audio it splits the remote speakers
  cleanly where the offline pyannote pass glued them together, so the final path
  drops pyannote entirely; persistent identity comes from `wespeaker_v2`
  voiceprints re-extracted per turn, not from any diarizer-internal embedding.
- **Merge:** speaker segments are aligned to transcript tokens by timestamp
  (`audioTimeRange`). The mic/system split makes this dramatically easier (mic =
  always one known speaker).

### Persistent identity (the feature you asked for)

- `SpeakerManager` extracts a **voiceprint embedding** per speaker.
- A local DB of enrolled speakers (name + embedding). On each meeting, observed
  embeddings are matched (cosine similarity) against enrolled voiceprints.
- **Enrollment UX:** name a speaker once (or enroll from a known-clean sample);
  thereafter they're auto-labeled in every future meeting.
- The mic track auto-enrolls **you** (it's always you), so the owner is named
  from day one.

**Streaming-diarization caps:** Sortformer handles ≤4 speakers per window, live
and in the final pass. Beyond that, identity re-segmentation recovers more
people than there are slots — the final pass re-embeds each turn with
`wespeaker_v2` and clusters by voice, so a slot Sortformer fused across two
speakers is pulled back apart and matched to distinct voiceprints. The live view
degrades gracefully (generic labels) and the final transcript gets identity
right even past four voices.

---

## 7. Two-pass accuracy model

1. **Live pass** (during meeting): SpeechTranscriber + Sortformer. Latency-
   optimized. Drives the readable transcript. Saved as provisional.
2. **Final pass** (meeting end / on demand): Parakeet TDT v3 batch ASR +
   Sortformer batch diarization + `wespeaker_v2` persistent-ID resolution, run
   over the continuously-saved AAC. Produces the canonical transcript that feeds
   summarization.

Optional third ASR engine (WhisperKit large-v3-turbo) selectable for
accent/jargon-heavy meetings, matching Trace's "fast vs accurate" toggle. Behind
the same `Transcriber` protocol.

---

## 8. Summarization

Summarization is the **most decoupled** part of the system: it runs once, at the
end, on finished transcript *text* — never on live audio. So it hides behind one
small interface, and the model is a **UI/config choice**.

```swift
struct MeetingNotes {            // structured output (see §8.3)
    var summary: String
    var decisions: [String]
    var actionItems: [ActionItem]
    var openQuestions: [String]
}

protocol Summarizer {
    var maxContextTokens: Int { get }          // 4096 for Apple FM; model-specific for MLX
    func summarize(_ transcript: String) async throws -> MeetingNotes
}
```

Two implementations behind it:

### 8.1 Apple Foundation Models (`AppleFMSummarizer`) — zero-setup default

- On-device ~3B model, free, no download, private.
- **Hard 4096-token context** (instructions + prompt + output combined,
  confirmed via Apple TN3193; read `SystemLanguageModel.contextSize` at runtime
  rather than hardcoding). No auto-trim — overflow throws.
- ⇒ **Map-reduce is mandatory**: chunk transcript to ~3,400 input tokens
  (~2,000 words), one *fresh* `LanguageModelSession` per chunk, carry a running
  summary forward, then a (possibly hierarchical) reduce pass. A 1-hour meeting
  ≈ 4–6 map chunks + reduce.
- Quality ≈ a good 3–4B model. Fine for chunked summaries; weakest at cross-
  chunk synthesis and prone to dropping nuance. Ground strictly in provided
  text, low temperature.
- `@Generable` guided generation gives type-safe structured output (constrained
  decoding → always parses). Keep schemas lean in the map phase (the schema
  itself costs context tokens), rich in the reduce phase.

### 8.2 MLX (`MLXSummarizer`) — the quality / long-context path

- In-process via **`mlx-swift-lm`** (`MLXLLM` + `MLXLMCommon`). No Python, no
  server, no IPC.
- **User-selectable model** (dropdown in settings). Recommended ladder:

  | Tier | Model | ~4-bit RAM | Context | Notes |
  |---|---|---|---|---|
  | **Default now (M2 Max)** | **Gemma 4 E4B** (or Gemma 3n E4B) | ~4 GB | 128K (3n: 32K) | Small, fast, one-pass for any meeting. Your pick until the M5. |
  | Light alt | Qwen3.5-9B-4bit | ~5.5 GB | 262K | "Most intelligent <10B"; instant load. |
  | **Quality (M5 Max / 64 GB)** | Qwen3-30B-A3B-Instruct-2507-4bit | ~17 GB | 256K | MoE (~3B active → fast). Near-cloud summary quality, one-pass. |
  | Upgrade path | Qwen3.5-35B-A3B-4bit | ~17–22 GB | 262K | Once MLX quants settle. Run at 6–8-bit on 64 GB. |

- Because these have 32K–256K context, a 1-hour meeting (~12–15k tokens) fits in
  **one pass** — map-reduce only needed for multi-hour or memory-capped runs.
- Use **non-thinking Instruct** variants (no `<think>` noise); strip stray
  `<think>` blocks defensively.

### 8.3 Summarization strategy (both engines)

- **Two prompts, not one:** (1) narrative summary; (2) a dedicated structured
  action-item extraction (owner / task / due date). A focused second pass
  extracts action items far more reliably than cramming everything into one
  prompt — worth it even when the whole transcript fits in context.
- Map-reduce machinery is shared; only chunk size + model differ. Greedy / low
  temperature for reproducibility.

### 8.4 Cloud escape hatch (not in v1, but cheap to keep)

Strictly on-device is the v1 product. But because the `Summarizer` protocol is
clean, a `FireworksSummarizer` / `ClaudeSummarizer` (OpenAI-compatible
`URLSession` client) is a ~30-line drop-in if a user ever wants a one-off
premium summary. We design against the chat-completions shape so this stays
trivial; we just don't ship or default to it.

---

## 9. Storage & retention

### Transcripts & metadata

- **SQLite via GRDB**: sessions, segments (speaker, text, start/end, channel),
  speaker voiceprints, summaries. (earl-scribe used a JSONL-on-disk contract
  between separate processes; since SayWhat is one app, a real DB is cleaner and
  queryable — and sets up future RAG-over-meetings.)

### Audio

- **AAC / m4a @ 32 kbps mono**, encoded continuously during capture. (WAV eats
  gigabytes/hour — a repeated Trace-thread complaint; AAC ~32 kbps mono is ~14
  MB/hour and plenty for re-transcription.)
- Mic and system tracks stored **separately** (preserves the diarization
  advantage for the final re-pass and for playback scrubbing).
- Written via a streaming encoder (`AVAssetWriter`) so audio on disk is always
  current up to ~the last second → crash recovery (see §10).

### Retention policy (your spec)

Settings offer a retention rule with a dropdown:

- **By age:** keep audio for *N* days (e.g. 7 / 30 / 90 / forever), then delete
  raw audio.
- **By size:** keep at most *X* GB of audio; evict oldest first when over.
- Optional: **delete audio after successful final transcription** (transcript +
  summary are tiny and kept regardless). Trace deletes raw audio post-transcript
  by default; we make it a choice.

Transcripts/summaries are text and effectively free — retention applies to
**audio** only. Deletions are logged and (optionally) go through a short
"trash" grace window rather than immediate `unlink`.

---

## 10. Reliability & crash recovery

Crash recovery is **the #1 unsolved problem in this app category** (consensus
from the Trace thread — MacWhisper notoriously loses recordings). We treat it as
a core requirement:

- **Continuous streaming encode to disk** (AAC/ADTS via `AVAssetWriter`), so the
  recording is durable up to the last moment before any crash.
- **Isolate the recorder from the ML engines.** A transcription or LLM crash
  must never take down the capture/encode path. (In-process, this means careful
  task isolation and actor boundaries; we evaluate an XPC helper for the ASR/LLM
  engines if in-process isolation proves insufficient.)
- **Journaled session state** so an interrupted meeting can be reopened and
  finalized (run the final pass over the recovered audio) on next launch.
- Assume thermal kills / jetsam can bypass graceful handlers — durability comes
  from the continuous write, not from a shutdown hook.

---

## 11. UI surface (v1)

- **Menu-bar presence** + a main window. Start/stop recording from the menu bar.
- **Live transcript view:** speaker-colored, auto-scrolling, volatile text
  shown lighter and committed on finalize; word-level highlight via
  `audioTimeRange`.
- **Session list / detail:** browse past meetings, read transcript, view
  summary, play back audio synced to transcript.
- **Settings:** capture mode (video/in-person), summarizer model dropdown
  (Gemma / Qwen / Apple FM), retention policy (days or GB), AEC opt-in, speaker
  enrollment management, vocabulary list.
- **Differentiator to consider early:** a **"flag this moment" hotkey** that
  drops a timestamped marker/note inline in the transcript mid-meeting — the
  single most-loved feature in the Trace discussion, cheap to build, and it makes
  downstream summaries better. Strong candidate for v1.

Carry forward from the earl-scribe SwiftUI viewer (it already exists and works):
`MenuBarView`, `SidebarView`, `TranscriptView`, `SessionDetailView`, the
`AppState`/view-model split, and the markdown/transcript rendering. We replace
its file-watching/CLI-spawning services with in-process capture + engine
services.

---

## 12. Differentiation & platform risk

Commenters expect **Apple to ship native on-device meeting transcription within
~12 months**. Raw transcription is therefore *not* a moat. We differentiate on
workflow and ownership:

- Persistent speaker identity across meetings.
- Mid-meeting "flag this moment."
- Calendar-named sessions; append-to-existing for recurring meetings.
- Local, private, owned — no subscription, no cloud.
- (Later) RAG / search over your entire meeting history.

---

## 13. Open questions

- **In-process vs XPC isolation** for the ML engines — start in-process, measure
  whether a crash in FluidAudio/MLX can be contained; escalate to XPC if not.
- **Sandbox + notarization** path for an eventual signed direct download
  (non-App-Store distribution was a repeated ask in the Trace thread). Does
  ScreenCaptureKit audio + our helper behavior fit a sandboxed entitlement set?
- **Model download UX** — first-run fetch of FluidAudio CoreML models + (if
  chosen) an MLX model is hundreds of MB to ~17 GB. Needs a clear, resumable,
  progress-tracked downloader, and storage accounting that ties into retention.
- **Live diarization >4 speakers** — confirm the graceful-degradation UX is
  acceptable, or evaluate LS-EEND (≤10 speakers) for the live path.
- **Custom vocabulary** — how far to go in v1 (post-correction vs Parakeet CTC
  boosting vs WhisperKit biasing).

---

## 14. Build order

- **Phase 0 — Capture & durability. ✓ Done.** SwiftUI scaffold; dual-track
  capture (mic + system) → continuous AAC to disk. Crash-safe recording proven
  end to end; local dev builds signed/sandboxed via a self-signed cert.
- **Phase 1 — Live transcript.** Apple SpeechTranscriber per track, on screen,
  volatile→final. The thing you want to *read*.
- **Phase 2 — Live diarization + enrollment.** FluidAudio Sortformer labels +
  `SpeakerManager` persistent identity.
- **Phase 3 — Final pass.** Parakeet TDT v3 batch + Sortformer batch diarization,
  merged into the authoritative transcript; `wespeaker_v2` identity resolution.
- **Phase 4 — Summaries.** `Summarizer` protocol → MLX (Gemma default) one-pass
  + Apple FM map-reduce fallback; two-prompt strategy.
- **Throughout** — retention policy, settings, the "flag this moment" hotkey,
  and the benchmark harness carried from earl-scribe (WER + diarization
  consistency + ±500 ms boundary accuracy).

---

## 15. Prior art & sources

- **earl-scribe** (`~/Code/ericboehs/earl-scribe`) — the predecessor prototype.
  Proved the FluidAudio (Parakeet + Sortformer) on-device direction and the
  separate-tracks diarization lesson. Its Swift ASR engine source was lost (only
  a compiled binary survives), which is *why* SayWhat is a fresh build. We reuse
  its SwiftUI viewer and benchmark harness.
- **FluidAudio** (github.com/FluidInference/FluidAudio, Apache-2.0) — the ASR +
  diarization + VAD + speaker-enrollment backbone. Note: the Sortformer *model*
  carries NVIDIA's Open Model License — check terms before commercial use.
- **Trace** (HN: news.ycombinator.com/item?id=48521236) — the closest shipping
  app; its HN thread is the source of the crash-recovery, echo-cancellation,
  storage, and differentiation lessons baked into this doc.
- **Apple** — SpeechAnalyzer/SpeechTranscriber (WWDC25 session 277) and
  Foundation Models (TN3193 for the 4096-token context + map-reduce guidance).
