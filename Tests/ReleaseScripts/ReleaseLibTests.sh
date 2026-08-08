#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT_DIR/scripts/release-lib.sh"

TEST_TEMP="$(mktemp -d -t crispvoice-release-lib-tests)"
trap '/bin/rm -rf "$TEST_TEMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_success() { "$@" >/dev/null 2>&1 || fail "expected success: $*"; }
expect_failure() { if "$@" >/dev/null 2>&1; then fail "expected failure: $*"; fi; }
expect_audio_input_failure() {
  local output

  if output="$("$@" 2>&1)"; then
    fail "expected failure: $*"
  fi
  [[ "$output" == *"Signed app is missing the required Boolean Audio Input entitlement."* ]] \
    || fail "expected Audio Input entitlement error: $output"
}

expect_success cv_validate_version "0.2.0"
expect_success cv_validate_version "12.34.56"
expect_failure cv_validate_version "v0.2.0"
expect_failure cv_validate_version "0.2"
expect_failure cv_validate_version "01.2.3"
expect_success cv_require_universal_arches "arm64 x86_64"
expect_success cv_require_universal_arches "x86_64 arm64"
expect_failure cv_require_universal_arches "arm64"
expect_failure cv_require_universal_arches "arm64 x86_64 i386"
[[ "$(cv_uppercase abcdef0123)" == "ABCDEF0123" ]] || fail "uppercase"

true_plist="$TEST_TEMP/audio-input-true.plist"
false_plist="$TEST_TEMP/audio-input-false.plist"
string_plist="$TEST_TEMP/audio-input-string.plist"
missing_plist="$TEST_TEMP/audio-input-missing.plist"

/usr/bin/plutil -create xml1 "$true_plist"
/usr/bin/plutil -insert 'com\.apple\.security\.device\.audio-input' -bool true "$true_plist"
/usr/bin/plutil -create xml1 "$false_plist"
/usr/bin/plutil -insert 'com\.apple\.security\.device\.audio-input' -bool false "$false_plist"
/usr/bin/plutil -create xml1 "$string_plist"
/usr/bin/plutil -insert 'com\.apple\.security\.device\.audio-input' -string true "$string_plist"
/usr/bin/plutil -create xml1 "$missing_plist"

expect_success cv_require_audio_input_entitlement "$true_plist" /usr/bin/plutil
expect_audio_input_failure cv_require_audio_input_entitlement "$false_plist" /usr/bin/plutil
expect_audio_input_failure cv_require_audio_input_entitlement "$string_plist" /usr/bin/plutil
expect_audio_input_failure cv_require_audio_input_entitlement "$missing_plist" /usr/bin/plutil

expected_entitlements="$TEST_TEMP/CrispVoice.entitlements"
sign_marker="$TEST_TEMP/release-sign-called"
/usr/bin/plutil -create xml1 "$expected_entitlements"
/usr/bin/plutil -insert 'com\.apple\.security\.device\.audio-input' -bool true "$expected_entitlements"
[[ "$(/usr/bin/plutil -extract 'com\.apple\.security\.device\.audio-input' raw -expect bool -o - "$expected_entitlements")" == true ]] \
  || fail "temporary entitlement fixture did not contain Audio Input Boolean true"

cat > "$TEST_TEMP/codesign" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == --force ]]
[[ "$2" == --sign ]]
[[ "$3" == TESTIDENTITY ]]
[[ "$4" == --options && "$5" == runtime ]]
[[ "$6" == --timestamp=none ]]
[[ "$7" == --entitlements && "$8" == "$CV_EXPECTED_ENTITLEMENTS" ]]
[[ "$9" == --requirements && "$10" == '=designated => identifier "com.crispvoice.app"' ]]
[[ "$11" == "$CV_EXPECTED_APP" ]]
[[ "$#" -eq 11 ]]
: > "$CV_SIGN_MARKER"
EOF
chmod +x "$TEST_TEMP/codesign"

CV_EXPECTED_ENTITLEMENTS="$expected_entitlements" \
CV_EXPECTED_APP="$TEST_TEMP/CrispVoice.app" \
CV_SIGN_MARKER="$sign_marker" \
  cv_sign_release_app \
    "$TEST_TEMP/codesign" \
    TESTIDENTITY \
    "$expected_entitlements" \
    '=designated => identifier "com.crispvoice.app"' \
    "$TEST_TEMP/CrispVoice.app"
[[ -e "$sign_marker" ]] || fail "release signer did not use Hardened Runtime and Audio Input entitlements"

/bin/rm -f "$sign_marker"
expect_failure cv_sign_release_app \
  "$TEST_TEMP/codesign" \
  TESTIDENTITY \
  "$TEST_TEMP/missing.entitlements" \
  '=designated => identifier "com.crispvoice.app"' \
  "$TEST_TEMP/CrispVoice.app"
[[ ! -e "$sign_marker" ]] || fail "release signer ran with a missing entitlement file"

/bin/ln -s "$expected_entitlements" "$TEST_TEMP/symlinked.entitlements"
expect_failure cv_sign_release_app \
  "$TEST_TEMP/codesign" \
  TESTIDENTITY \
  "$TEST_TEMP/symlinked.entitlements" \
  '=designated => identifier "com.crispvoice.app"' \
  "$TEST_TEMP/CrispVoice.app"
[[ ! -e "$sign_marker" ]] || fail "release signer ran with a symlinked entitlement file"

echo "ReleaseLibTests: PASS"
