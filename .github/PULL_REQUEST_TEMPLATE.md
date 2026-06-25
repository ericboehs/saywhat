<!--
Thanks for contributing to SayWhat! Tick every box, or strike it out with a
one-line reason. PRs can't merge until the checklist is complete and CI is green.
See QUALITY.md for the full quality bar.
-->

## What & why

<!-- One or two sentences: what does this change do, and why? -->

## How I tested it

<!-- Commands run, scenarios exercised, hardware (e.g. M2 Max), meeting type. -->

## Checklist

**Foundations**
- [ ] Builds clean on macOS 26 / Apple Silicon with warnings-as-errors
- [ ] Swift 6 strict concurrency respected (no new data-race warnings)

**Architecture invariants** (see DESIGN.md)
- [ ] Mic and system audio remain separate end to end
- [ ] New/changed engines stay behind their protocol (`Transcriber`/`Diarizer`/`Summarizer`)
- [ ] No new network calls (on-device only); no telemetry
- [ ] Audio durability / crash safety not regressed

**Quality**
- [ ] `swiftformat --lint` and `swiftlint --strict` are clean
- [ ] Tests added/updated (Swift Testing); patch coverage ≥ 80%
- [ ] ML/audio changes: golden-file + WER/DER no-regress checks pass
- [ ] No secrets committed; gitleaks/OSV-Scanner clean (CodeQL runs post-merge on `main`)

**Docs & commits**
- [ ] Conventional Commit messages
- [ ] DESIGN.md / CLAUDE.md / QUALITY.md updated if behavior or contracts changed
- [ ] Public API has DocC comments
