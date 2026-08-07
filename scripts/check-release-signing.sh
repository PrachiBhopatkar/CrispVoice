#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/release/config.sh"

cert="$ROOT_DIR/release/CrispVoice-Early-Access-Release.cer"
[[ -f "$cert" ]] || { echo "Missing public signing certificate." >&2; exit 1; }

actual_sha256="$(shasum -a 256 "$cert" | awk '{print toupper($1)}')"
[[ "$actual_sha256" == "$CRISPVOICE_SIGNING_CERT_SHA256" ]] || {
  echo "Public signing certificate fingerprint mismatch." >&2
  exit 1
}

if [[ "${1:-}" == "--require-private-key" ]]; then
  matches="$(security find-identity -v -p codesigning \
    | awk -v sha="$CRISPVOICE_SIGNING_IDENTITY_SHA1" -v name="$CRISPVOICE_SIGNING_IDENTITY" \
      'index($0, sha) && index($0, "\"" name "\"") { count++ } END { print count+0 }')"
  [[ "$matches" == "1" ]] || {
    echo "Expected exactly one matching CrispVoice signing identity; found $matches." >&2
    exit 1
  }
fi

echo "Release signing configuration verified."
