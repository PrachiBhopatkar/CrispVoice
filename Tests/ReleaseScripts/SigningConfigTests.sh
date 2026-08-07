#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT_DIR/release/config.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ "$CRISPVOICE_REPOSITORY" == "PrachiBhopatkar/CrispVoice" ]] || fail "repository"
[[ "$CRISPVOICE_APP_NAME" == "CrispVoice" ]] || fail "app name"
[[ "$CRISPVOICE_BUNDLE_ID" == "com.crispvoice.app" ]] || fail "bundle id"
[[ "$CRISPVOICE_MIN_MACOS" == "13.0" ]] || fail "minimum macOS"
[[ "$CRISPVOICE_SIGNING_IDENTITY" == "CrispVoice Early Access Release" ]] || fail "identity name"
[[ "$CRISPVOICE_SIGNING_IDENTITY_SHA1" =~ ^[0-9A-F]{40}$ ]] || fail "SHA-1 format"
[[ "$CRISPVOICE_SIGNING_CERT_SHA256" =~ ^[0-9A-F]{64}$ ]] || fail "SHA-256 format"

actual_sha256="$(shasum -a 256 "$ROOT_DIR/release/CrispVoice-Early-Access-Release.cer" | awk '{print toupper($1)}')"
[[ "$actual_sha256" == "$CRISPVOICE_SIGNING_CERT_SHA256" ]] || fail "public certificate fingerprint"

echo "SigningConfigTests: PASS"
