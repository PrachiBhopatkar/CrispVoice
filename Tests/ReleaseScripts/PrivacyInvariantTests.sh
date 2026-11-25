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

# --- Task 10: public setup, privacy, troubleshooting, and destination ---
# --- verification documentation.                                     ---
#
# These checks require README.md, docs/privacy.md, and
# docs/troubleshooting.md to cover the public-facing setup, privacy, and
# recovery content described in design section 14. Coverage is split across
# the three documents the way a reader would expect to find it (README =
# setup, privacy.md = data-flow/IAM guarantees, troubleshooting.md =
# recovery), not duplicated verbatim in all three.

readme="README.md"
privacy="docs/privacy.md"
troubleshooting="docs/troubleshooting.md"

for document in "$readme" "$privacy" "$troubleshooting"; do
  [[ -f "$document" ]] || fail "$document does not exist"
done

## README.md: setup instructions for both providers.

require_pattern "$readme" \
  "Anthropic API key" \
  "the Anthropic setup path"
require_pattern "$readme" \
  "macOS Keychain" \
  "the Anthropic Keychain storage statement"
require_pattern "$readme" \
  "Amazon Bedrock" \
  "the Amazon Bedrock provider option"
require_pattern "$readme" \
  "AWS profile" \
  "the Bedrock AWS profile input"
require_pattern "$readme" \
  "AWS Region" \
  "the Bedrock AWS Region input"
require_pattern "$readme" \
  "model or inference-profile identifier" \
  "the Bedrock model/inference-profile identifier input"
require_pattern "$readme" \
  "Claude Opus 4\\.8 \\(US\\)" \
  "the Opus 4.8 US preset name"
require_pattern "$readme" \
  "us\\.anthropic\\.claude-opus-4-8" \
  "the Opus 4.8 US preset's exact model ID"
require_pattern "$readme" \
  "docs/privacy\\.md" \
  "a link to the privacy documentation"
require_pattern "$readme" \
  "docs/troubleshooting\\.md" \
  "a link to the troubleshooting documentation"

## docs/privacy.md: data-flow, IAM, and destination guarantees.

require_pattern "$privacy" \
  "directly to the configured (AWS )?Bedrock Runtime endpoint" \
  "the direct Bedrock destination statement"
require_pattern "$privacy" \
  "api\\.anthropic\\.com" \
  "the direct Anthropic destination statement"
require_pattern "$privacy" \
  "AWS SSO/OIDC/STS endpoints" \
  "the AWS authentication traffic exception"
require_pattern "$privacy" \
  "Audio.*never leaves" \
  "the local-audio invariant"
require_pattern "$privacy" \
  "Transcription.*local" \
  "the local-transcription invariant"
require_pattern "$privacy" \
  "no developer backend, proxy, telemetry, analytics, or content-bearing logging" \
  "the developer-service, analytics, and logging prohibition"
require_pattern "$privacy" \
  "AWS credentials are never stored by CrispVoice" \
  "the AWS credential-storage prohibition"
require_pattern "$privacy" \
  "bedrock:InvokeModel" \
  "the required IAM InvokeModel permission"
require_pattern "$privacy" \
  "[Ss]ervice [Cc]ontrol [Pp]olic" \
  "Service Control Policy considerations"
require_pattern "$privacy" \
  "destination Region" \
  "inference-profile destination-Region permission considerations"
require_pattern "$privacy" \
  "cross-Region" \
  "the cross-Region routing disclosure"
require_pattern "$privacy" \
  "access[- ]key ID" \
  "the AWS access-key-ID input prohibition"
require_pattern "$privacy" \
  "secret access key" \
  "the AWS secret-access-key input prohibition"
require_pattern "$privacy" \
  "session token" \
  "the AWS session-token input prohibition"
require_pattern "$privacy" \
  "account ID" \
  "the AWS account-ID input prohibition"
require_pattern "$privacy" \
  "user.{0,10}identity ARN" \
  "the AWS user/identity ARN input prohibition"
require_pattern "$privacy" \
  "inference-profile ARN" \
  "the sole model/application inference-profile ARN exception"
require_pattern "$privacy" \
  "validated office example" \
  "Midway scoped only as a validated office example"

reject_pattern "$privacy" \
  "Midway is (a |an |the )?(supported|official|required)" \
  "language implying Midway is a supported CrispVoice authentication product"
reject_pattern "$privacy" \
  "public CrispVoice dependency" \
  "language implying Midway is a public CrispVoice dependency"
reject_pattern "$privacy" \
  "(always|all traffic) (remains|stays|is kept) (in|within) (a single Region|us-west-2)" \
  "a promise that all Bedrock traffic stays in a single Region"

## docs/troubleshooting.md: recovery flows and Finder/PATH guidance.

require_pattern "$troubleshooting" \
  "credential_process" \
  "credential_process troubleshooting coverage"
require_pattern "$troubleshooting" \
  "unavailable or.{0,10}expired" \
  "safe recovery guidance for an unavailable or expired AWS session"
require_pattern "$troubleshooting" \
  "[Aa]ccess [Dd]enied" \
  "safe recovery guidance for access-denied errors"
require_pattern "$troubleshooting" \
  "Region or model" \
  "safe recovery guidance for a Region/model mismatch"
require_pattern "$troubleshooting" \
  "throttl" \
  "safe recovery guidance for throttling"
require_pattern "$troubleshooting" \
  "custom .*profile" \
  "custom AWS profile troubleshooting coverage"
require_pattern "$troubleshooting" \
  "works in Terminal" \
  "the Terminal-works/Finder-fails scenario"
require_pattern "$troubleshooting" \
  "absolute path" \
  "the absolute credential-process path recommendation"
require_pattern "$troubleshooting" \
  "Finder-launched apps.{0,20}(don't|do not) inherit" \
  "the Finder/login-shell PATH explanation"
require_pattern "$troubleshooting" \
  "CrispVoice never starts (an? )?(SSO|Midway)" \
  "the statement that CrispVoice never initiates SSO/Midway login"
require_pattern "$troubleshooting" \
  "appends these folders to its own .PATH." \
  "the description of CrispVoice's fixed PATH extension"
require_pattern "$troubleshooting" \
  "does not invoke a login shell" \
  "the statement that CrispVoice does not start a login shell"

reject_pattern "$troubleshooting" \
  "(always|all traffic) (remains|stays|is kept) (in|within) (a single Region|us-west-2)" \
  "a promise that all Bedrock traffic stays in a single Region"

echo "Privacy invariant checks passed."
