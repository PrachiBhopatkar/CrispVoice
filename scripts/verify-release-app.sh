#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/release/config.sh"
source "$ROOT_DIR/scripts/release-lib.sh"

if [[ "$#" -ne 2 ]]; then
  echo "Usage: $0 APP_PATH VERSION" >&2
  exit 1
fi

APP_PATH="$1"
VERSION="$2"

cv_validate_version "$VERSION" || cv_die "Version must use MAJOR.MINOR.PATCH without leading zeroes."
[[ -d "$APP_PATH" ]] || cv_die "Release app does not exist: $APP_PATH"

INFO_PLIST="$APP_PATH/Contents/Info.plist"
[[ -f "$INFO_PLIST" ]] || cv_die "Release app is missing Contents/Info.plist."

bundle_id="$(cv_plist_string CFBundleIdentifier "$INFO_PLIST")"
bundle_version="$(cv_plist_string CFBundleShortVersionString "$INFO_PLIST")"
bundle_executable="$(cv_plist_string CFBundleExecutable "$INFO_PLIST")"
minimum_macos="$(cv_plist_string LSMinimumSystemVersion "$INFO_PLIST")"

[[ "$bundle_id" == "$CRISPVOICE_BUNDLE_ID" ]] || cv_die "Unexpected bundle identifier."
[[ "$bundle_version" == "$VERSION" ]] || cv_die "Unexpected bundle version."
[[ "$minimum_macos" == "$CRISPVOICE_MIN_MACOS" ]] || cv_die "Unexpected minimum macOS version."

executable_path="$APP_PATH/Contents/MacOS/$bundle_executable"
[[ -f "$executable_path" ]] || cv_die "Release app executable is missing."

architectures="$(/usr/bin/lipo -archs "$executable_path")"
cv_require_universal_arches "$architectures" || cv_die "Release executable must contain exactly arm64 and x86_64."

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

certificate_dir="$(mktemp -d -t crispvoice-release-certificates)"
trap '/bin/rm -rf "$certificate_dir"' EXIT
certificate_prefix="$certificate_dir/certificate"
entitlements_plist="$certificate_dir/entitlements.plist"

/usr/bin/codesign \
  --display \
  --entitlements "$entitlements_plist" \
  --xml \
  "$APP_PATH" >/dev/null 2>&1 \
  || cv_die "Unable to read signed app entitlements."
cv_require_audio_input_entitlement "$entitlements_plist" /usr/bin/plutil

/usr/bin/codesign --display --extract-certificates="$certificate_prefix" "$APP_PATH"
[[ -f "${certificate_prefix}0" ]] || cv_die "Release signature has no leaf certificate."

actual_certificate_sha256="$(cv_certificate_sha256 "${certificate_prefix}0")"
[[ "$actual_certificate_sha256" == "$CRISPVOICE_SIGNING_CERT_SHA256" ]] || cv_die "Release signing certificate fingerprint mismatch."

/usr/bin/codesign \
  --verify \
  --deep \
  --strict \
  -R="certificate leaf = H\"$CRISPVOICE_SIGNING_IDENTITY_SHA1\" and identifier \"$CRISPVOICE_BUNDLE_ID\"" \
  "$APP_PATH"

echo "Release app verification passed for $CRISPVOICE_APP_NAME $VERSION."
