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

documents=(
  "AGENTS.md"
  "docs/superpowers/specs/2026-06-12-crispvoice-design.md"
)

if rg -q -- "only outbound (network call|connection).*api\\.anthropic\\.com" AGENTS.md; then
  fail "AGENTS.md still contains the old unconditional Anthropic-only outbound-call invariant"
fi

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
    "no developer backend, proxy, telemetry, or content-bearing logging" \
    "the developer-service and logging prohibition"
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
