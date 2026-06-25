# Security Policy

## Reporting a vulnerability

Please **do not open a public issue** for security vulnerabilities.

Instead, use GitHub's private vulnerability reporting:
**Security → Report a vulnerability** on this repository. You'll get an
acknowledgement within a few days.

## Scope & threat model

SayWhat is an **on-device** app: meeting audio, transcripts, summaries, and
speaker voiceprints never leave the user's machine. The security properties we
care most about:

- **No data exfiltration.** The only permitted network calls are first-run model
  downloads and the optional calendar lookup. A finding that shows audio,
  transcripts, or voiceprints leaving the device is **critical**.
- **Least privilege.** The app requests only the entitlements it needs
  (microphone, screen recording). New entitlements are reviewed and justified.
- **Supply chain.** Dependencies are scanned (Dependabot + OSV-Scanner); we
  pin versions and avoid known-compromised tooling (e.g. Trivy, per the March
  2026 incidents). Release builds are signed (Developer ID, Hardened Runtime),
  notarized via `notarytool`, and stapled; Sparkle updates are EdDSA-signed.
- **No secrets in the repo.** Enforced by gitleaks + GitHub push protection.

## Supported versions

Pre-1.0: only the latest `main` / latest release receives fixes.
