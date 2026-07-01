# Benchmarks

Accuracy benchmarking for SayWhat's transcription, diarization, and segmentation
— and a way to score on-device engines against a cloud SOTA baseline on the same
audio.

Everything here is driven by the `saywhat` CLI over the **shared JSONL schema**
(`TranscriptJSONL`): a transcript is one compact JSON object per utterance, one
per line. A *hypothesis* (what an engine produced) and a *reference* (hand-checked
ground truth) are the same format, and `saywhat bench` scores one against the
other.

## Privacy: fixtures are local-only

This repo is public, and real meeting audio/transcripts must **never** be
committed (see the root `.gitignore`). So `Benchmarks/` is gitignored except this
README — the audio (`*.wav`/`*.m4a`) and the ground-truth/hypothesis JSONL live on
your machine only. A committable, synthetic fixture is tracked separately; this
file documents the workflow, not the data.

Lay a local fixture out like:

```
Benchmarks/
  <name>/
    audio.wav          # 16 kHz mono (the on-device path requires 16 kHz)
    reference.jsonl    # ground truth, hand-corrected
    <engine>.jsonl     # a hypothesis from one engine (regenerated, disposable)
```

## Workflow

Build the CLI once (`swift build`), then — using a local fixture named
`team-calendar-60s` as the running example:

```bash
# 1. Produce a hypothesis from any audio file with the on-device pass.
swift run saywhat transcribe Benchmarks/team-calendar-60s/audio.wav \
  --out Benchmarks/team-calendar-60s/ondevice.jsonl

# 2. (optional) Produce a cloud SOTA hypothesis for the same file.
#    Key stays in the process — never written to disk, a commit, or this repo.
DEEPGRAM_API_KEY=$(op read "op://Personal/Deepgram/credential") \
  swift run saywhat transcribe Benchmarks/team-calendar-60s/audio.wav \
    --engine deepgram --out Benchmarks/team-calendar-60s/deepgram.jsonl

# 3. Score each hypothesis against the reference.
swift run saywhat bench Benchmarks/team-calendar-60s/ondevice.jsonl \
  Benchmarks/team-calendar-60s/reference.jsonl --system "on-device (Parakeet+Sortformer)"
swift run saywhat bench Benchmarks/team-calendar-60s/deepgram.jsonl \
  Benchmarks/team-calendar-60s/reference.jsonl --system "Deepgram Nova-3"
```

The hypothesis files are disposable — regenerate them anytime from the audio. Only
`reference.jsonl` is authored by hand (or adapted from an existing SRT/markdown
ground truth).

## Metrics (`SayWhatBench`)

`saywhat bench` reports four numbers; all are pure functions of the two JSONL
files, no models or audio involved.

- **WER** — word error rate: token-level Levenshtein over the whole transcript,
  broken out into substitutions / insertions / deletions. Segmentation differences
  don't affect it (the text is scored as one stream).
- **DER** — diarization error rate: time-weighted fraction of reference speech the
  hypothesis mislabels, after the hypothesis's cluster ids are optimally mapped
  onto the reference's (ids are arbitrary; only the grouping is judged).
- **Cluster consistency** — the coarser, legible check: fraction of reference
  utterances landing in the hypothesis cluster that dominates their speaker.
- **Boundary accuracy** — fraction of reference utterance start/end times the
  hypothesis matches within ±500 ms, plus the mean absolute boundary error.

## Engines

| `--engine` | What | Network |
|---|---|---|
| `ondevice` (default) | On-device final pass — FluidAudio Parakeet TDT v3 + Sortformer | no |
| `deepgram` | Cloud SOTA reference — Deepgram Nova-3, diarized | **yes** |

The Deepgram adapter lives in the `saywhat` CLI target and is **never linked into
the app** — `SayWhatCore` and the app make no network calls (CLAUDE.md). It exists
only to give the on-device numbers a SOTA baseline to be measured against.
