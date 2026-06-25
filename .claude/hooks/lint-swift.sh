#!/bin/bash
# Claude Code PostToolUse hook: keep Swift edits clean as they happen.
#
# On every Write/Edit of a .swift file we:
#   1. auto-format it with SwiftFormat (mechanical; uses .swiftformat) — no
#      reason to nag about whitespace,
#   2. lint it with `swiftlint --strict` (uses .swiftlint.yml) and, if anything
#      remains, BLOCK with the violations so they're fixed now, not at commit.
# This mirrors the CI `lint` gate (QUALITY.md §2/§9) at edit time.

if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' '{"decision": "block", "reason": "Required dependency jq is not installed; Swift lint hook cannot determine the file to lint."}'
  exit 0
fi

input=$(cat)
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty')

# Only act on Swift source that still exists on disk.
if [[ ! "$file_path" =~ \.swift$ ]]; then exit 0; fi
if [[ ! -f "$file_path" ]]; then exit 0; fi

# Lint from the file's own package root (nearest ancestor with Package.swift) so
# the .swiftformat / .swiftlint.yml configs are discovered.
project_dir=$(cd "$(dirname "$file_path")" && pwd)
while [[ "$project_dir" != "/" && ! -f "$project_dir/Package.swift" ]]; do
  project_dir=$(dirname "$project_dir")
done
if [[ -f "$project_dir/Package.swift" ]]; then
  cd "$project_dir" || exit 0
fi

output=""

# 1. Auto-format in place (idempotent, mechanical). Note it if it changed.
if command -v swiftformat >/dev/null 2>&1; then
  before=$(shasum "$file_path" 2>/dev/null | awk '{print $1}')
  swiftformat "$file_path" >/dev/null 2>&1
  after=$(shasum "$file_path" 2>/dev/null | awk '{print $1}')
  if [[ "$before" != "$after" ]]; then
    output+="SwiftFormat reformatted the file (re-read before further edits)."$'\n\n'
  fi
else
  output+="swiftformat not found (brew install swiftformat) — formatting skipped."$'\n\n'
fi

# 2. Lint --strict and surface any remaining violations.
if command -v swiftlint >/dev/null 2>&1; then
  lint_out=$(swiftlint lint --strict --quiet "$file_path" 2>/dev/null)
  if [[ -n "$lint_out" ]]; then
    output+="SwiftLint issues (--strict):"$'\n'"$lint_out"$'\n'
  fi
else
  output+="swiftlint not found (brew install swiftlint) — lint skipped."$'\n'
fi

if [[ -n "$output" ]]; then
  jq -n --arg reason "$output" '{"decision": "block", "reason": $reason}'
fi
