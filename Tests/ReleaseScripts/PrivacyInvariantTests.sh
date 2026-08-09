#!/usr/bin/env bash

set -euo pipefail

fail() {
  echo "Privacy invariant check failed: $1" >&2
  exit 1
}

require_pattern() {
  local file="$1"
  local pattern="$2"
  local description="$3"

  rg -q -- "$pattern" "$file" || fail "$file is missing $description"
}

reject_pattern() {
  local file="$1"
  local pattern="$2"
  local description="$3"

  if rg -q -- "$pattern" "$file"; then
    fail "$file still contains $description"
  fi
}

documents=(
  "AGENTS.md"
  "docs/superpowers/specs/2026-06-12-crispvoice-design.md"
)

reject_pattern AGENTS.md \
  "only outbound (network call|connection).*api\\.anthropic\\.com" \
  "the old unconditional Anthropic-only outbound-call invariant"
reject_pattern AGENTS.md \
  "rewrites.*using the user's.*Anthropic API key" \
  "an Anthropic-only introductory rewrite description"
reject_pattern "docs/superpowers/specs/2026-06-12-crispvoice-design.md" \
  "Claude remains the post-stop rewrite engine.*user's own API key" \
  "an Anthropic-only architecture-update description"
reject_pattern "docs/superpowers/specs/2026-06-12-crispvoice-design.md" \
  "rewrite is done by the user's own Claude" \
  "an Anthropic-only value-proposition description"

for document in "${documents[@]}"; do
  require_pattern "$document" \
    "user-selected Anthropic or Amazon Bedrock rewrite destination" \
    "the user-selected provider boundary"
  require_pattern "$document" \
    "AWS SSO/OIDC/STS endpoints" \
    "AWS SSO/OIDC/STS authentication traffic"
  require_pattern "$document" \
    "credential_process" \
    "credential_process authentication support"
  require_pattern "$document" \
    "initiated only for the explicitly selected standard AWS profile/provider" \
    "the selected AWS authentication scope"
  require_pattern "$document" \
    "no developer backend, proxy, telemetry, analytics, or content-bearing logging" \
    "the developer-service, analytics, and logging prohibition"
  require_pattern "$document" \
    "Audio.*never leaves" \
    "the local-audio invariant"
  require_pattern "$document" \
    "Transcription.*local" \
    "the local-transcription invariant"
  require_pattern "$document" \
    "AWS credentials are never stored by CrispVoice" \
    "the AWS credential-storage prohibition"
done

echo "Privacy invariant checks passed."
