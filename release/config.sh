#!/usr/bin/env bash

_RELEASE_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

readonly CRISPVOICE_REPOSITORY="kirtanework/CrispVoice"
readonly CRISPVOICE_APP_NAME="CrispVoice"
readonly CRISPVOICE_BUNDLE_ID="com.crispvoice.app"
readonly CRISPVOICE_MIN_MACOS="13.0"
readonly CRISPVOICE_SIGNING_IDENTITY="CrispVoice Early Access Release"
readonly CRISPVOICE_PUBLIC_CERT="$_RELEASE_CONFIG_DIR/CrispVoice-Early-Access-Release.cer"
readonly CRISPVOICE_SIGNING_IDENTITY_SHA1="$(
  /usr/bin/openssl x509 -inform DER -in "$CRISPVOICE_PUBLIC_CERT" -noout -fingerprint -sha1 \
    | /usr/bin/sed 's/^.*=//; s/://g' \
    | /usr/bin/tr '[:lower:]' '[:upper:]'
)"
readonly CRISPVOICE_SIGNING_CERT_SHA256="$(
  /usr/bin/shasum -a 256 "$CRISPVOICE_PUBLIC_CERT" \
    | /usr/bin/awk '{print toupper($1)}'
)"
