# Contributing to SayWhat

Thanks for your interest. SayWhat is an on-device meeting recorder/transcriber/
diarizer/summarizer for Apple Silicon Macs. Before you start, read:

- **[DESIGN.md](DESIGN.md)** — architecture and scope (the source of truth).
- **[QUALITY.md](QUALITY.md)** — the quality bar every change must meet.
- **[CLAUDE.md](CLAUDE.md)** — fast orientation + the hard invariants.

## Requirements

- macOS 26 (Tahoe) or later, Apple Silicon.
- Xcode 26.5+ (pinned in CI).
- [SwiftFormat](https://github.com/nicklockwood/SwiftFormat), [SwiftLint](https://github.com/realm/SwiftLint),
  [Periphery](https://github.com/peripheryapp/periphery), [lefthook](https://github.com/evilmartians/lefthook),
  [gitleaks](https://github.com/gitleaks/gitleaks):

  ```bash
  brew install swiftformat swiftlint periphery lefthook gitleaks
  lefthook install   # sets up pre-commit/pre-push hooks
  ```

## Workflow

1. **Branch** off `main` (don't commit to `main` directly).
2. **Build & test:**
   ```bash
   swift build
   swift test --enable-code-coverage
   ```
   ⚠️ The MLX summarizer needs Xcode (Metal shaders) — build/run the app target
   in Xcode when exercising it; `swift build` alone won't compile MLX kernels.
3. **Lint & format before committing** (the hooks do this for you):
   ```bash
   swiftformat .          # format
   swiftformat --lint .   # verify (what CI runs)
   swiftlint --strict
   periphery scan         # dead code (uses the committed baseline)
   ```
4. **Commit** with [Conventional Commits](https://www.conventionalcommits.org/)
   (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`). **Never use
   `git commit --no-verify`** — fix the hook failure instead. `CHANGELOG.md` is
   generated from these messages by [git-cliff](https://git-cliff.org) (config
   in `cliff.toml`; regenerate with `git-cliff -o CHANGELOG.md`) — don't edit it
   by hand.
5. **Open a PR.** Fill in the template and tick every checklist box (or strike
   it with a one-line reason). CI must be green and the checklist complete to
   merge.

## Testing expectations

- New logic → **Swift Testing** (`@Test`/`#expect`). UI/perf → **XCTest**.
- Hardware (`AVAudioEngine`, `ScreenCaptureKit`) goes behind injectable
  protocols (`swift-dependencies`) so the logic around it is testable.
- ML/audio code is tested with **golden-file fixtures + tolerance** and the
  **WER/DER no-regress** harness — not by mocking the models. See QUALITY.md §5.
- Aim for **≥ 80% patch coverage**; don't chase a high absolute number.

## The invariants we won't break

These are non-negotiable (see QUALITY.md §3). A PR that violates one needs a
design discussion first, not just code review:

1. Mic and system audio stay **separate**.
2. Engines stay **behind protocols**.
3. **On-device only** — no network beyond model download / optional calendar.
4. **Audio is durable** — a crash never loses a recording.
5. **Echo cancellation is opt-in** and never seizes the input device.

## Reporting issues

Use the issue templates. For anything security-sensitive, see
[SECURITY.md](.github/SECURITY.md) — don't open a public issue.

## License

By contributing, you agree your contributions are licensed under the project's
[MIT](LICENSE) license.
