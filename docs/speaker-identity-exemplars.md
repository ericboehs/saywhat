# Speaker identity: the exemplar-set model

> Design note + migration plan. Folds into DESIGN.md §6 once accepted. **No code
> written yet** — this is the spec to review first.

## 1. The problem (from real data)

A live test (3 clips: Theo, then a gaming voice, then an EV ad) produced a clean
**live** transcript but a smeared **final** one — Theo's name bled across all
three speakers. The cause is in the persistent directory, not the transcript:

```
Theo                count=3      ← reinforced twice
Zwag, Zwag, Zwag    count=1,1,2  ← three duplicate identities, same name
Speaker 1 … 12      count=1 each ← twelve orphan auto-mints, never named
```

**15 voiceprints for ~3 people.** Two compounding bugs created it:

1. **Cross-session matching under-fires**, so the same voice is *re-minted* as a
   new `Speaker N` every session instead of being recognized.
2. **Every mint persists and becomes a future match candidate**, so the
   directory grows without bound, which makes (1) *worse* (more confusable
   near-duplicates) — a positive-feedback mess. Renaming each fresh mint to
   "Zwag" just forks parallel "Zwag" identities.

Final-pass matching then resolves each of a session's slots against all 15
prints by greedy cosine ≥ 0.5 and lands on the wrong one. Live avoids this: it
keeps a stable slot and smooths the name over time.

## 2. Goals / non-goals

**Goals**
- One **person** is one identity, even with several recordings of their voice.
- Duplicates stop being *born* (rename binds to a known person; un-named mints
  don't pollute future matching).
- Reinforcement stops blurring distinct takes into mush.

**Non-goals (tracked separately)**
- Fixing *why* cross-session matching under-fires (slot-embedding quality vs.
  `matchThreshold`). The exemplar model reduces the damage but isn't the cure —
  see §9.
- Final-pass temporal smoothing (a separate improvement).

## 3. The model

Replace "one centroid per name" with **Person → set of exemplar voiceprints**:

- A **Person** has a stable id and a name.
- A Person holds one or more **exemplars** (the current `Voiceprint`: an
  embedding + its reinforcement `count`). Each exemplar is one acoustic take —
  room mic vs. phone vs. tired — kept *distinct*, never averaged across.
- A slot **matches a Person** by their **best** exemplar:
  `score(slot, person) = max over person.exemplars of cosine(slot, exemplar)`.

Why best-exemplar beats one centroid: averaging two genuinely different takes of
the same person produces a vector matching *neither* well. Keeping exemplars
separate captures intra-speaker variation without blur. "Three Zwags" was never
wrong as *evidence* — it was wrong as three rival top-level *identities*.

## 4. Schema + migration (GRDB)

New table + a nullable owner column on the existing one:

```
person(id TEXT PRIMARY KEY, name TEXT NOT NULL)
voiceprint: + person_id TEXT NULL  REFERENCES person(id)   -- NULL = un-named mint
```

`name` moves off `voiceprint` (the exemplar) onto `person` — a name is an
attribute of the identity, not of each take.

**Migration `addPersonExemplars`:**
1. Create `person`; add `voiceprint.person_id`.
2. For each existing row whose name is **not** a generic `Speaker N`: find-or-
   create a `person` with that name, set `person_id`. The three "Zwag" rows
   collapse onto one Zwag person with three exemplars; "Theo" becomes one person,
   one exemplar.
3. **Drop the legacy `Speaker N` rows** — they're stale per-session mints that
   leaked into persistence; keeping them just re-pollutes. (Decision D1.)
4. Drop `voiceprint.name`.

This one-time pass turns the polluted 15 rows into **2 persons (Theo, Zwag)**
with a few exemplars — the cleanup we'd otherwise do by hand.

## 5. Matching changes

`VoiceprintMatcher` / `SpeakerResolver` operate at **person granularity**:

- Candidate set is **named persons only**. Un-named mints (`person_id NULL`) are
  **never** cross-session match candidates — this single rule kills the orphan
  explosion. (Decision D2.)
- Score each slot against each person by best exemplar (§3).
- Greedy mutual exclusion as today, but a *person* claims ≤1 slot and a *slot*
  claims ≤1 person — so two slots can't both collapse onto Zwag.
- A slot matching nobody mints a **new un-named exemplar**, displayed `Speaker N`
  for that session, awaiting a rename.

## 6. Rename = bind to a person (the action that stops duplicates)

`renameSpeaker(slot, name)` becomes a *binding*, not a row-rename:

- **Name already exists as a Person P:** attach this slot's exemplar to P
  (`person_id = P`), delete any forked duplicate. **Similarity guard:** if the
  exemplar is far from *all* of P's exemplars (below a consolidation floor
  `τ_same`), don't blend silently — surface "this doesn't sound like the
  existing P; add anyway / keep separate?" This is the name-collision guard (two
  real "John"s).
- **New name:** create Person, attach the exemplar.

## 7. Reinforcement, re-scoped (supersedes the held PR)

Reinforcement and exemplar-growth become two arms of one gate. On a confident
match to person P whose best exemplar is `e`:

- **slot very close to `e`** (≥ `τ_reinforce`, e.g. 0.6): fold into `e`
  (count-weighted `reinforced(with:)`) — sharpen the take.
- **matched P but moderately far from `e`** (between match threshold and
  `τ_reinforce`): add a **new exemplar** of P — capture the variation instead of
  averaging it in.
- Cap exemplars per person (e.g. keep the N most diverse) to bound growth.
  (Decision D3.)

The held `feat/voiceprint-reinforcement` PR's `reinforced(with:)` math and tests
carry over unchanged; only the *call site* moves from "average into the one
print" to "fold into the matched exemplar." Nothing is thrown away.

## 8. Live namer

`LiveSpeakerNamer` stays strictly read-only. It just matches against **named
persons** (best exemplar) instead of a flat voiceprint list, and reports the
person's name. No minting, no writes — unchanged invariant.

## 9. Upstream leak (parallel, not in this change)

Even with all the above, a named person can fail to match next session and
re-mint. Likely the final-pass slot embedding is taken over a *mis-segmented*
slot (mixed audio) → noisy vector → below threshold. Worth investigating
independently: slot-audio selection in `FinalPass.identityEmbeddings`, and
whether 0.5 is the right cross-session floor. Exemplar-set softens this (more
exemplars = more chances to clear threshold) but doesn't replace the fix.

## 10. Type / API blast radius

- **New:** `Person { id: UUID; name: String }`; `VoiceprintStore` gains
  `persons() -> [Person: [Voiceprint]]` (or a `PersonDirectory` value type);
  exemplar CRUD (`attach`, `pruneUnnamed`).
- **`Voiceprint`:** drop `name`; add `personID: UUID?`. Keep `embedding`,
  `count`, `reinforced(with:)`.
- **`SpeakerResolver`:** resolves slots → `Person` (with the matched exemplar);
  `SpeakerResolution` carries minted-persons / reinforced-exemplars /
  new-exemplars.
- **`FinalPass.Outcome.speakers`:** `[Int: Person]` instead of `[Int: Voiceprint]`.
- **`CaptureModel` / views:** `speakers[slot]` is a `Person`; `renameSpeaker`
  becomes the §6 binding.

## 11. Build order (each phase shippable + tested)

- **A — schema & model.** `Person`, migration (§4, named→person/exemplars, drop
  `Speaker N`), person-granularity matching (§5), un-named mints non-matchable.
  *This alone fixes the smearing for the current DB.*
- **B — rename binding** (§6) with the similarity guard.
- **C — reinforcement re-scoped** (§7), folding in the held PR.
- **D — upstream match-quality** (§9), in parallel.

## 12. Test plan

- **Migration:** three same-name rows → one person / three exemplars; `Speaker N`
  rows dropped.
- **Matching:** best-exemplar wins; greedy exclusion at person level; un-named
  mints excluded from candidates.
- **Rename binding:** attach to existing person; dedupe; `τ_same` guard fires on
  a far exemplar.
- **Reinforcement gate:** close → fold into exemplar; mid → new exemplar; cap
  enforced.
- **Golden-file:** the 3-clip session yields three distinct identities, no
  cross-speaker bleed.

## 13. Decisions to confirm

- **D1.** Drop legacy `Speaker N` rows on migration (recommended) vs. keep them.
- **D2.** Un-named mints are ephemeral / never cross-session match candidates
  (recommended) vs. persistent.
- **D3.** Cap exemplars per person, ~5–8, keep most diverse (recommended) vs.
  unbounded.
- **D4.** Name on `Person` only / normalized (recommended) vs. keep denormalized
  on `Voiceprint` to shrink the refactor.
