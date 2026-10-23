#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT_DIR/release/config.sh"

VERSION="${CRISPVOICE_INSTALLER_TEST_VERSION:-0.2.0}"
ARCHIVE_BASENAME="CrispVoice-$VERSION-macos-universal.zip"
ARCHIVE="$ROOT_DIR/dist/$ARCHIVE_BASENAME"
CHECKSUM="$ARCHIVE.sha256"
INSTALLER="$ROOT_DIR/scripts/install.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$ARCHIVE" ]] || fail "missing Task 2 fixture: $ARCHIVE"
[[ -f "$CHECKSUM" ]] || fail "missing Task 2 fixture: $CHECKSUM"
[[ -f "$INSTALLER" ]] || fail "scripts/install.sh does not exist"

/usr/bin/grep -Fq "$CRISPVOICE_SIGNING_IDENTITY_SHA1" "$INSTALLER" \
  || fail "installer does not embed the pinned SHA-1 certificate fingerprint"
/usr/bin/grep -Fq "$CRISPVOICE_SIGNING_CERT_SHA256" "$INSTALLER" \
  || fail "installer does not embed the pinned SHA-256 certificate fingerprint"

TEST_TEMP="$(mktemp -d -t crispvoice-installer-tests)"
trap '/bin/rm -rf "$TEST_TEMP"' EXIT

fixture_root="$TEST_TEMP/fixture"
release_dir="$fixture_root/releases/download/v$VERSION"
test_root="$TEST_TEMP/install-root"
destination="$test_root/Applications/CrispVoice.app"

/bin/mkdir -p "$release_dir" "$test_root"
/bin/cp "$ARCHIVE" "$release_dir/$ARCHIVE_BASENAME"
/bin/cp "$CHECKSUM" "$release_dir/$ARCHIVE_BASENAME.sha256"

run_installer() {
  CRISPVOICE_INSTALLER_TEST_MODE=1 \
  CRISPVOICE_VERSION_OVERRIDE="$VERSION" \
  CRISPVOICE_RELEASE_BASE_URL="file://$fixture_root/releases/download" \
  CRISPVOICE_INSTALL_ROOT="$test_root" \
  CRISPVOICE_ASSUME_YES=1 \
    /bin/bash "$INSTALLER"
}

# Sentinel preference/Keychain fixtures, isolated beneath $TEST_TEMP (never
# the real ~/Library/Preferences or Keychain). These stand in for the six
# non-secret Preferences.swift UserDefaults keys and for the Anthropic
# Keychain item, so upgrade/rejection/rollback can be proven to leave
# anything outside the installed app bundle byte-for-byte untouched.
sentinel_root="$TEST_TEMP/sentinel"
preferences_dir="$sentinel_root/Library/Preferences"
preferences_plist="$preferences_dir/com.crispvoice.app.plist"
keychain_sentinel="$sentinel_root/Library/Keychains/keychain-sentinel.dat"

/bin/mkdir -p "$preferences_dir" "$(/usr/bin/dirname "$keychain_sentinel")"

/usr/bin/plutil -create xml1 "$preferences_plist"
/usr/bin/plutil -insert rewriteProvider -string "bedrock" "$preferences_plist"
/usr/bin/plutil -insert anthropicModelName -string "sentinel-anthropic-model-$RANDOM$RANDOM" "$preferences_plist"
/usr/bin/plutil -insert bedrockProfileName -string "sentinel-profile-$RANDOM$RANDOM" "$preferences_plist"
/usr/bin/plutil -insert bedrockRegion -string "us-test-sentinel-1" "$preferences_plist"
/usr/bin/plutil -insert bedrockModelID -string "sentinel.model.$RANDOM$RANDOM" "$preferences_plist"
/usr/bin/plutil -insert variantCount -integer 3 "$preferences_plist"

/usr/bin/openssl rand -hex 64 > "$keychain_sentinel"

[[ -f "$preferences_plist" ]] || fail "sentinel preference fixture was not created"
[[ -f "$keychain_sentinel" ]] || fail "sentinel Keychain fixture was not created"

preferences_sentinel_sha256="$(/usr/bin/shasum -a 256 "$preferences_plist" | /usr/bin/awk '{print $1}')"
keychain_sentinel_sha256="$(/usr/bin/shasum -a 256 "$keychain_sentinel" | /usr/bin/awk '{print $1}')"

verify_sentinels_preserved() {
  local context="$1"
  local prefs_now
  local keychain_now

  [[ -f "$preferences_plist" ]] \
    || fail "$context: preference sentinel file is missing"
  [[ -f "$keychain_sentinel" ]] \
    || fail "$context: Keychain sentinel file is missing"

  prefs_now="$(/usr/bin/shasum -a 256 "$preferences_plist" | /usr/bin/awk '{print $1}')"
  keychain_now="$(/usr/bin/shasum -a 256 "$keychain_sentinel" | /usr/bin/awk '{print $1}')"

  [[ "$prefs_now" == "$preferences_sentinel_sha256" ]] \
    || fail "$context: preference sentinel changed (installer touched preference data outside its scope)"
  [[ "$keychain_now" == "$keychain_sentinel_sha256" ]] \
    || fail "$context: Keychain sentinel changed (installer touched Keychain data outside its scope)"
}

run_installer

[[ -d "$destination" ]] || fail "installer did not create Applications/CrispVoice.app"
"$ROOT_DIR/scripts/verify-release-app.sh" "$destination" "$VERSION" \
  || fail "installed app failed release verification"
verify_sentinels_preserved "successful install"

bundle_executable="$(/usr/bin/plutil -extract CFBundleExecutable raw -o - \
  "$destination/Contents/Info.plist")"
installed_executable="$destination/Contents/MacOS/$bundle_executable"
original_executable_sha256="$(/usr/bin/shasum -a 256 "$installed_executable" | /usr/bin/awk '{print $1}')"

missing_entitlement_extract="$TEST_TEMP/missing-entitlement-extract"
missing_entitlement_app="$missing_entitlement_extract/CrispVoice.app"
/bin/mkdir "$missing_entitlement_extract"
/usr/bin/ditto -x -k "$ARCHIVE" "$missing_entitlement_extract"
/usr/bin/codesign \
  --force \
  --sign "$CRISPVOICE_SIGNING_IDENTITY_SHA1" \
  --options runtime \
  --timestamp=none \
  --requirements "=designated => certificate leaf = H\"$CRISPVOICE_SIGNING_IDENTITY_SHA1\" and identifier \"$CRISPVOICE_BUNDLE_ID\"" \
  "$missing_entitlement_app"

missing_entitlement_output="$(/usr/bin/codesign --display --entitlements - --xml "$missing_entitlement_app" 2>&1)"
[[ "$missing_entitlement_output" != *"<plist"* ]] \
  || fail "negative fixture unexpectedly emitted an entitlement plist"

/usr/bin/ditto -c -k --keepParent "$missing_entitlement_app" "$release_dir/$ARCHIVE_BASENAME"
(
  cd "$release_dir"
  /usr/bin/shasum -a 256 "$ARCHIVE_BASENAME" > "$ARCHIVE_BASENAME.sha256"
)

set +e
output="$(run_installer 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "installer accepted a signed app without Audio Input entitlement"
[[ "$output" == *"Signed app is missing the required Boolean Audio Input entitlement."* ]] \
  || fail "installer rejected the fixture for the wrong reason: $output"

after_rejection_sha256="$(/usr/bin/shasum -a 256 "$installed_executable" | /usr/bin/awk '{print $1}')"
[[ "$after_rejection_sha256" == "$original_executable_sha256" ]] \
  || fail "missing-entitlement release changed the installed executable"
verify_sentinels_preserved "rejected archive (missing entitlement)"

set +e
output="$("$ROOT_DIR/scripts/verify-release-app.sh" "$missing_entitlement_app" "$VERSION" 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "release verifier accepted a signed app without Audio Input entitlement"
[[ "$output" == *"Signed app is missing the required Boolean Audio Input entitlement."* ]] \
  || fail "release verifier rejected the fixture for the wrong reason: $output"

/bin/cp "$ARCHIVE" "$release_dir/$ARCHIVE_BASENAME"
/bin/cp "$CHECKSUM" "$release_dir/$ARCHIVE_BASENAME.sha256"

/usr/bin/printf 'corrupted archive\n' > "$release_dir/$ARCHIVE_BASENAME"
if run_installer >/dev/null 2>&1; then
  fail "installer accepted a corrupted archive"
fi

after_corruption_sha256="$(/usr/bin/shasum -a 256 "$installed_executable" | /usr/bin/awk '{print $1}')"
[[ "$after_corruption_sha256" == "$original_executable_sha256" ]] \
  || fail "corrupted archive changed the installed executable"
verify_sentinels_preserved "rejected archive (corrupted)"

/bin/cp "$ARCHIVE" "$release_dir/$ARCHIVE_BASENAME"
/usr/bin/xattr -w com.crispvoice.installer-test previous-install "$destination"

if CRISPVOICE_TEST_LAUNCH_FAILURE=1 run_installer >/dev/null 2>&1; then
  fail "injected launch failure unexpectedly succeeded"
fi

restored_marker="$(/usr/bin/xattr -p com.crispvoice.installer-test "$destination" 2>/dev/null || true)"
[[ "$restored_marker" == "previous-install" ]] \
  || fail "injected launch failure did not restore the previous app"

after_rollback_sha256="$(/usr/bin/shasum -a 256 "$installed_executable" | /usr/bin/awk '{print $1}')"
[[ "$after_rollback_sha256" == "$original_executable_sha256" ]] \
  || fail "injected launch failure changed the installed executable"
"$ROOT_DIR/scripts/verify-release-app.sh" "$destination" "$VERSION" \
  || fail "restored app failed release verification"
verify_sentinels_preserved "rollback"

echo "InstallerTests: PASS"
