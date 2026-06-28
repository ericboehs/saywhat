# Identity-driven re-segmentation

Status: **proposed** (spec). Follows [speaker-identity-exemplars.md](speaker-identity-exemplars.md),
which fixed *who a voiceprint belongs to*. This fixes *which audio belongs to
which voice* — the layer underneath identity.

## The problem, from a real recording

Session `1782611830` (4 voices: me, then Theo, then MKBHD, then Zwag). The live
diarizer's own output, straight out of `transcript.md`:

```
[0:04] Speaker 1: …the channel is where the context lives…   ← Theo
[1:09] Speaker 1: I've heard of the slate truck.             ← MKBHD
[1:12] Speaker 2: …first drive of this slate truck today…    ← MKBHD
[1:48] Speaker 1: All right, everybody, welcome back…        ← MKBHD
[1:55] Speaker 3: Running lethal tempo triumph…              ← Zwag
```

**Two distinct people (Theo and MKBHD) landed in one slot, "Speaker 1."** MKBHD
was additionally split across Speaker 1 *and* Speaker 2. The segmentation is
wrong before identity ever runs.

Everything downstream is slot-granular, so the error compounds:

- The final pass extracts **one** identity embedding for the whole Speaker-1 slot
  — a Theo+MKBHD *blend* (`FinalPass.identityEmbeddings` → `SpeakerAudio.samples(forSlot:)`
  concatenates *all* of a slot's turns). The blend matches enrolled **Theo**
  (Theo is enrolled, MKBHD is not), so the entire slot — including the slate-truck
  turns — is labeled Theo.
- Renaming is slot-granular too (`Transcript.renamingSpeaker(slot:to:)`). Renaming
  the mislabeled slate-truck turn to "MKBHD" relabels the genuinely-Theo turns as
  well, because they share slot 1.

This is **not** a voiceprint bug. The exemplar work was correct and is done (the
DB is clean: Theo + Zwag, 4 exemplars, 0 orphans). This is a **diarization /
segmentation** failure, and neither identity matching nor renaming can separate
what the diarizer already fused into one slot.

### Why the current architecture can't catch it

`HybridDiarizer` takes **turns** from Sortformer and borrows **embeddings** from
offline pyannote (`SpeakerTimelineFuser` maps each Sortformer slot to the pyannote
cluster it overlaps most). The whole design assumes "*Sortformer splits the turns
cleanly*" (its own doc comment) and only needs pyannote to attach identity. This
recording breaks that assumption: Sortformer's **slots** merged two speakers. The
fuser can't un-merge a slot — it only attaches one embedding per slot.

## The key observation

Theo and MKBHD are in **separate turns** of the same slot (`[0:04…1:09]` vs
`[1:09], [1:48]`), not interleaved within a single turn. So we do **not** need to
subdivide turns to separate them — we need to stop trusting the diarizer's *slot
assignment* and instead **re-cluster the turns by their own identity embeddings**.

The system already has the right tool for this: `wespeaker_v2` via
`SpeakerEmbedder` — the same space `VoiceprintMatcher` already trusts for "same
voice." We use it today only per-slot for naming. The fix is to use it per-**turn**
for *segmentation*: embed turns, cluster turns whose voices match, and let the
clusters — not Sortformer's slots — define who's who.

## Goal / non-goals

**Goal:** within a meeting, group turns by *actual* voice (so one mis-merged
diarizer slot splits back into Theo-turns and MKBHD-turns), then resolve each
group to an enrolled `Person` or an un-named mint. Renaming a group relabels only
that voice's turns.

**Non-goals:**
- Replacing Sortformer's turn *boundaries* (when speech starts/stops). We keep its
  segmentation; we override its *speaker labels*.
- Handling true within-turn speaker changes (two people inside one continuous
  turn). Out of scope until a recording demands it; turns are short enough that
  this is rare.
- Real-time re-segmentation. This is a **final-pass** improvement. The live path's
  slots can stay imperfect; the authoritative transcript is what must be right.

## Approach

Insert an **identity re-segmentation** step in the final pass, between diarization
and the merge, replacing the current per-slot `resolveIdentities`:

```
diarize() ─▶ turns (Sortformer slots)
                 │
                 ▼
   ┌─────────────────────────────────────────────┐
   │ SpeakerResegmenter                           │
   │  1. embed each turn (wespeaker_v2)           │
   │  2. cluster turns by cosine  → voice groups  │
   │  3. match each group to enrolled Person      │
   │  4. re-key turns by group id                 │
   └─────────────────────────────────────────────┘
                 │
                 ▼
   re-segmented timeline + group→ResolvedSpeaker names
                 │
                 ▼
            merge() (unchanged: dominantSpeaker over new turns)
```

The merge is untouched: it already attributes each transcript segment to the
dominant speaker over its time window and looks the name up per slot. We just hand
it turns keyed by *identity group* instead of Sortformer slot, and a names map
keyed the same way.

### Algorithm

1. **Per-turn embedding.** For each turn, gather its samples
   (`SpeakerAudio.samples(forSlot:)` constrained to that single turn's range) and
   embed. A turn shorter than the embed floor (`minIdentitySamples`, 1 s) yields no
   vector — handled in step 4.
2. **Group the embeddable turns by voice — identity first** (D5). A turn that
   matches an enrolled person (best exemplar ≥ threshold) is anchored to *that
   person's* group; only turns matching nobody are clustered among themselves
   (agglomerative, merge when similarity ≥ `τ_split`) to discover unknown speakers.
   Anchoring on the stable enrolled exemplars — not turn-to-turn similarity — is
   what keeps one known voice together: a short turn's own embedding is noisy, so
   two genuine Zwag turns can each clear the threshold against Zwag's clean
   exemplars yet fall below it *relative to each other*. Pure turn-to-turn
   clustering therefore shattered Zwag across many "Speaker N" groups (the
   "monstrosity" on session-1782614511). Identity is the anchor; mutual similarity
   only has to separate the unknowns. (Theo's turns and MKBHD's still separate even
   inside one fused Sortformer slot — Theo matches enrolled Theo, MKBHD matches
   nobody and clusters on its own.)
3. **Resolve** each group to identity: average is *not* used — score the group's
   turns against enrolled persons by best exemplar, with the existing greedy,
   mutually-exclusive `SpeakerResolver` policy, so two groups can't both claim
   Theo. Unmatched groups mint an un-named "Speaker N" (not persisted — exemplar
   rules from the prior spec still hold).
4. **Assign short / unembeddable turns** to a group: attach each to the group of
   the temporally nearest embedded turn. We deliberately *ignore* the diarizer's
   own slot — its slot assignment is the very thing this pass distrusts, so using
   it as an adjacency prior backfires (see D3). This keeps "Here." and "I want"
   with the right neighbor.
5. **Re-key** every turn to its group id and emit a `SpeakerTimeline` plus a
   `[groupID: ResolvedSpeaker]` map for the merge's names.

### Where pyannote goes

If we re-embed and re-cluster per turn with `wespeaker_v2`, the pyannote embedding
borrowing (`SpeakerTimelineFuser`, `OfflinePyannoteDiarizer` in the final path) is
**redundant for identity** — we no longer need pyannote's per-cluster vectors. We
still want Sortformer for turn boundaries. So the final-pass diarizer could
collapse from `HybridDiarizer(Sortformer + pyannote)` back to just Sortformer,
with `SpeakerResegmenter` doing all identity/clustering. That's a real
simplification — but it's a **decision** (D4), because pyannote's clustering is a
useful second opinion and dropping it is hard to walk back.

## Decisions

- **D1 — clustering unit.** *Per-turn* (recommended; sufficient for the observed
  failure, simplest) vs *fixed sliding windows* (handles within-turn changes too,
  but more knobs and more short-clip noise). Recommend per-turn now; revisit
  windows only if a within-turn merge shows up.
- **D2 — `τ_split` source.** Reuse the existing fuzziness → threshold mapping
  (`AppSettings.matchThreshold`, default 0.5) so one slider governs both "same
  voice for clustering" and "same voice for enrollment" (recommended), vs a
  separate dedicated clustering threshold.
- **D3 — short-turn assignment.** The first cut preferred an embedded turn from
  the short turn's **own Sortformer slot**, falling back to nearest-in-time. We
  dropped the same-slot prior in favor of **pure temporal nearest**: distrusting
  the slot is the whole premise of this pass, so using it even as a weak adjacency
  hint contradicts the design. (Note: the stray one-word interjections seen on
  session-1782611830 — "what", "want", "get" stamped as Theo — turned out **not**
  to come from this step at all, but from the *merge's* gap fallback hardcoding
  slot 0; see "Merge gap fallback" below.) Time-padded re-embedding of the short
  turn remains a possible future refinement.

### Merge gap fallback (the real interjection bug)

`TranscriptMerger` attributes each system **word** to `dominantSpeaker(in:)` over
the re-segmented timeline. A word that lands in a **gap** between turns (a brief
pause the diarizer didn't cover) has no dominant speaker, and the code fell back
to a hardcoded **slot 0**. Before re-segmentation slot 0 was a generic "Speaker 0";
*after* re-segmentation group 0 is a *named* person (the first voice to appear —
Theo here), so every gap word got stamped with that name. That, not short-turn
clustering, produced the "Theo: what / want / get" fragments scattered through
MKBHD's and Zwag's sections. Fix: fall back to `nearestSpeaker(to:)` (the turn
closest in time) instead of slot 0, so a gap word joins whoever was actually
speaking around it.
- **D5 — grouping anchor: identity-first vs pure clustering.** *Resolved by
  session-1782614511.* Pure agglomerative turn-to-turn clustering shattered an
  enrolled voice (Zwag) into many groups because short turns embed too noisily to
  clear the threshold *against each other*, even when each clears it against the
  clean enrolled exemplars. Anchor on identity instead: a turn matching an enrolled
  person joins that person's group directly; only unknown turns cluster among
  themselves. This keeps a known voice whole and makes the result robust to the
  diarizer's run-to-run variance (the same recording grouped differently between
  two passes). Trade-off: a turn that *falsely* matches an enrolled person joins
  the wrong group — but the threshold guards that, and a false same-person match is
  far rarer than noisy self-similarity.

- **D4 — keep or drop pyannote in the final pass.** Drop it and let
  `SpeakerResegmenter` own clustering (simpler, recommended *after* the new path is
  proven) vs keep `HybridDiarizer` and run re-segmentation on top (safer, more
  compute). Recommend: build re-segmentation first **on top of** today's pipeline
  (low risk), then drop pyannote in a follow-up once the fixture passes.

## Build phases

- **Phase R1 — `SpeakerResegmenter` (pure core).** New type taking turns +
  per-turn embeddings + enrolled directory + `SpeakerResolver`, returning a
  re-keyed `SpeakerTimeline` and `[Int: ResolvedSpeaker]`. Fully unit-testable with
  scripted embeddings (no CoreML). Clustering + resolve + short-turn assignment.
- **Phase R2 — wire into `FinalPass`.** Replace per-slot `resolveIdentities` with a
  per-turn embedding pass feeding `SpeakerResegmenter`; emit the re-keyed timeline
  to the merge. Keep `HybridDiarizer` for now (D4 deferred).
- **Phase R3 — non-destructive rename (parallel, small).** Let the UI correct a
  residual mistake without clobbering a whole group: per-utterance rename or
  "split this turn into a new speaker." Useful regardless of R1/R2.
- **Phase R4 — simplify (optional).** Drop offline pyannote from the final path
  (D4) once the fixture is green; `SpeakerResegmenter` owns identity end to end.

## Test plan

- **Golden fixture from this recording.** Save session `1782611830`'s system track
  + ground truth (me/Theo/MKBHD/Zwag turn ranges) into the benchmark harness. The
  pass condition: Theo's turns and MKBHD's turns end up in **different** groups
  even though Sortformer put them in one slot; Zwag is its own group; Theo's group
  resolves to enrolled Theo; MKBHD mints a new speaker.
- **`SpeakerResegmenter` unit tests** (scripted embeddings, no models):
  - two turns of one Sortformer slot with dissimilar embeddings split into two
    groups; two with similar embeddings stay one group;
  - a sub-floor turn attaches to its temporally nearest group (slot ignored);
  - a system word in a diarization gap is attributed to the nearest turn, not
    slot 0 (`SpeakerTimeline.nearestSpeaker`, `TranscriptMerger` gap fallback);
  - greedy mutual exclusion holds at the *group* level (two groups can't both take
    Theo);
  - an unmatched group mints an un-named speaker and is **not** persisted.
- **Regression:** the existing `FinalPass` identity tests keep passing (a
  single-voice slot still resolves exactly as before).
- **Rename:** renaming one group leaves the other groups' labels untouched
  (the failure Eric hit).
```
