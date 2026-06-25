# SayWhat — Quality Bar

The definition of done. Every change to SayWhat is expected to meet this bar
before it merges to `main`. Modeled on the
[Website Specification checklist](https://specification.website/checklist/):
each item is a short imperative rule with a status badge and a one-line
rationale anchored to something **checkable** — a command, a flag, or a number.

**Status legend**

| Badge | Meaning |
|---|---|
| **Required** | Must hold. CI enforces it; PRs that violate it don't merge. |
| **Recommended** | Strong default. Deviate only with a noted reason in the PR. |
| **Optional** | Nice to have; adopt when it helps. |
| **Avoid** | Known trap. Don't introduce it. |

> Most items map to a CI gate (see §9) and the
> [PR checklist](.github/PULL_REQUEST_TEMPLATE.md). The honor system is for
> things CI can't see; everything else is a required status check.

---

## 1. Foundations (build & language)

- **Swift 6 language mode** — *Required* — `swift-tools-version` ≥ 6.0 and the
  Swift 6 language mode is on for every target; the language version is not
  silently pinned back to 5.
- **Strict concurrency = complete** — *Required* — data-race safety is enforced
  at compile time (`SwiftSetting.strictConcurrency` / `-strict-concurrency=complete`).
  This is our cheapest defense against real-time audio threading bugs; respect
  actor isolation across the capture/engine boundary.
- **Warnings as errors** — *Required* — CI builds with `-warnings-as-errors`
  (`SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`). Local builds may relax it while
  iterating; CI does not.
- **Builds clean on `macos-26`** — *Required* — the project builds and tests on
  the GA Apple-Silicon `macos-26` runner with the pinned Xcode (see §9). No
  reliance on a single developer's local toolchain.
- **Apple Silicon / macOS 26 only** — *Required* — we target macOS 26 (Tahoe) on
  Apple Silicon. Don't add Intel or pre-26 conditionals; the design depends on
  SpeechAnalyzer + Foundation Models.

## 2. Code style

- **`swiftformat --lint` is clean** — *Required* — formatting is mechanical and
  not a review topic; `nicklockwood/SwiftFormat` is the formatter of record
  (config in `.swiftformat`).
- **`swiftlint --strict` is clean** — *Required* — SwiftLint enforces
  conventions and smells (config in `.swiftlint.yml`); `--strict` means warnings
  fail CI.
- **One formatter only** — *Avoid* — don't run Apple `swift format` and
  nicklockwood `SwiftFormat` together; they fight. We use nicklockwood.
- **No new dead code** — *Recommended* — `periphery scan` (with a committed
  baseline) shows no newly unused symbols; delete code rather than leaving it
  unreferenced.

## 3. Architecture invariants

These are the load-bearing rules from [DESIGN.md](DESIGN.md). Breaking one is a
design regression, not a style nit.

- **Mic and system audio stay separate** — *Required* — separate capture,
  storage, and transcriber instances end to end. Never mix into one stream; the
  channel split is our primary diarization signal.
- **Engines live behind protocols** — *Required* — `Transcriber`, `Diarizer`,
  `Summarizer`. No concrete model type leaks into the UI or pipeline; swapping a
  model touches one implementation file.
- **On-device only** — *Required* — no network calls except first-run model
  download and optional calendar lookup. No telemetry, no analytics, no
  transcript/audio upload. A cloud `Summarizer` is a documented opt-in, never the
  default and not in v1.
- **Audio is durable** — *Required* — capture streams to disk continuously; an
  ASR/LLM crash cannot lose a recording or stop capture. Recovery is tested
  (§5).
- **Echo cancellation is opt-in** — *Required* — AEC defaults off and never
  reconfigures or seizes the system input device (the bug that broke Teams calls
  in Trace).

## 4. Concurrency & real-time

- **Real-time factor < 1.0** — *Required* — the live pipeline keeps up with
  input: per-chunk processing stays under the buffer deadline on an M2 Max.
  Measured by a perf test (§5), gated against a baseline.
- **No blocking the audio path** — *Required* — no synchronous I/O, locks held
  across `await`, or main-actor hops on the capture/encode path. Heavy work
  (ASR, LLM) runs off the capture actor.
- **Latency budget is measured, not assumed** — *Recommended* — live-caption
  end-to-end latency is tracked over time; regressions are caught, not
  discovered in a meeting.

## 5. Testing

- **Swift Testing for new logic** — *Required* — new unit/integration tests use
  `@Test`/`#expect` (Swift Testing, the 2026 default). XCTest only where it's
  still required (below).
- **XCTest for UI & performance** — *Required* — UI automation (`XCUITest`) and
  performance/latency baselines (`XCTMetric`/`measure`) use XCTest; Swift Testing
  has no equivalent yet.
- **Hardware behind a seam** — *Required* — `AVAudioEngine`/`ScreenCaptureKit`
  sit behind injectable protocols (via `swift-dependencies`) so pure DSP/
  view-model logic is unit-testable without hardware.
- **Golden-file ML tests with tolerance** — *Required* — ASR/diarization are
  tested against committed reference fixtures with **tolerance** assertions
  (epsilon / RMSE / boundary ±500 ms), never exact float equality. Force CPU
  compute units and pin model versions for determinism.
- **WER/DER no-regress gate** — *Required* — transcription WER and diarization
  consistency are scored against the carried-over benchmark harness (from
  earl-scribe: 60 s 2-speaker clip + ground truth) and fail the build if they
  regress beyond a stored delta.
- **Crash-recovery test** — *Required* — there is a test that simulates an
  interrupted session and asserts the audio is recoverable and the session can be
  finalized.

## 6. Coverage

- **Patch coverage ≥ 80%** — *Required* — new/changed lines are covered (Codecov
  `patch` gate). This forces tests on new code without punishing the untestable
  hardware layer.
- **Project coverage: no regression** — *Recommended* — absolute target ~70%
  with a 1% drop threshold; we don't chase a high absolute number on an
  audio/ML app.
- **Exclude the untestable layer** — *Required* — generated code, SwiftUI
  previews, and the AV/hardware adapter are excluded in `codecov.yml`; the pure
  logic they wrap is not.

## 7. Security & supply chain

- **CodeQL clean** — *Required* — GitHub CodeQL (Swift, GA) runs on `main`
  (post-merge) and weekly with no unresolved high/critical alerts. It's kept off
  the PR critical path because it's slow (~13 min) and rarely changes verdict
  between a PR and its merge. (CodeQL Swift needs an explicit `swift build`
  step — no `autobuild`.)
- **No secrets in history** — *Required* — `gitleaks` (pre-commit + CI) and
  GitHub push protection are clean; no keys, certs, or tokens committed.
- **Dependencies scanned** — *Required* — Dependabot (SwiftPM, GA) is enabled and
  `osv-scanner scan -L Package.resolved` reports no unfixed high/critical CVEs.
- **Trivy in CI** — *Avoid* — Trivy was supply-chain-compromised twice in March
  2026; use OSV-Scanner (and Syft+Grype for SBOM) instead.
- **Minimal entitlements + Hardened Runtime** — *Required* — every entitlement is
  justified in review; Hardened Runtime is on for release builds. Adding an
  entitlement is a reviewable finding.

## 8. Docs & commits

- **Conventional Commits** — *Required* — `feat:`/`fix:`/`docs:`… ; never
  `git commit --no-verify`. Enables automated changelogs and signals
  changelog-worthiness at commit time.
- **Docs track behavior** — *Required* — a change that alters architecture or a
  public contract updates [DESIGN.md](DESIGN.md) / [CLAUDE.md](CLAUDE.md) in the
  same PR. Code and docs disagreeing is a bug.
- **Public API has DocC** — *Recommended* — public types/methods carry DocC
  comments; `swift package generate-documentation` builds without errors.

## 9. CI gates (what actually enforces this)

GitHub Actions on `macos-26` (Apple Silicon), Xcode pinned via
`maxim-lobanov/setup-xcode`. Required status checks before merge:

1. **lint** — `swiftformat --lint` + `swiftlint --strict` (github-actions
   reporter for inline annotations).
2. **test** — `swift test --enable-code-coverage` (Swift Testing) → `llvm-cov
   export` lcov → Codecov, **patch gate 80%**. Logs via `xcbeautify`.
3. **deadcode** *(optional)* — `periphery scan` with baseline.
4. **security** *(PR gate)* — gitleaks (SARIF) + OSV-Scanner on
   `Package.resolved`. Dependabot enabled at repo level.
5. **codeql** *(on `main` + weekly, not a PR gate)* — CodeQL (Swift, explicit
   `swift build`); slow (~13 min) and rarely flips between a PR and its merge.
6. **docs** *(on `main`)* — DocC → GitHub Pages.
7. **release** *(on tag)* — archive → codesign (Developer ID, Hardened Runtime)
   → `notarytool submit --wait` → `stapler staple` → `create-dmg` →
   `generate_appcast` (Sparkle, EdDSA-signed) → GitHub Release.

**Branch protection** — *Required* — `lint`, `test` (+coverage), `security` must
be green and ≥1 review before merge; squash-merge for clean history; the
[PR checklist](.github/PULL_REQUEST_TEMPLATE.md) must be fully ticked.

---

## Toolchain at a glance

| Concern | Tool | Status |
|---|---|---|
| Format | nicklockwood/**SwiftFormat** | primary |
| Lint | **SwiftLint** (`--strict`) | primary |
| Dead code | **Periphery** (baseline) | recommended |
| Unit/integration tests | **Swift Testing** | primary |
| UI / perf tests | **XCTest** (XCUITest, XCTMetric) | required where applicable |
| DI / test seams | **swift-dependencies** | primary |
| SwiftUI / golden files | **swift-snapshot-testing** | primary |
| Coverage | llvm-cov → **Codecov** (patch 80%) | primary |
| SAST | **CodeQL** (Swift) | primary |
| Secrets | **gitleaks** + push protection | primary |
| Deps | **Dependabot** + **OSV-Scanner** | primary |
| SBOM | **Syft** (+ Grype) | optional |
| CI | **GitHub Actions** `macos-26` + **xcbeautify** | primary |
| Pre-commit | **lefthook** | recommended |
| Project gen | plain **SPM**, **Tuist** when needed | primary |
| Changelog | Conventional Commits + **git-cliff** | recommended |
| Updates | **Sparkle** (EdDSA appcast) | primary (release) |
| Notarization | **notarytool** (NOT altool) | required (release) |
| ~~Trivy~~ | — | **avoid** (compromised 2026) |
