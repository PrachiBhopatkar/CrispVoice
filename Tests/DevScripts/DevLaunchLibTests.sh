#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT_DIR/scripts/dev-launch-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_success() { "$@" >/dev/null 2>&1 || fail "expected success: $*"; }
expect_failure() { if "$@" >/dev/null 2>&1; then fail "expected failure: $*"; fi; }

identity_one='  1) 151F66C8B0F20E6B0682394EEF7A3084495B50F1 "Apple Development: Example (TEAM123456)"'
identity_other='  2) 533D56B942C39F246C7A9ADB4B796AD9E248B0C0 "CrispVoice Early Access Release"'
identity_two='  2) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Development: Other (OTHER12345)"'

single="$(cv_dev_require_single_identity "$identity_one
$identity_other")" || fail "one Apple Development identity was rejected"
[[ "$single" == $'151F66C8B0F20E6B0682394EEF7A3084495B50F1\tApple Development: Example (TEAM123456)' ]] \
  || fail "single identity output"
expect_failure cv_dev_require_single_identity "$identity_other"
expect_failure cv_dev_require_single_identity "$identity_one
$identity_two"

expect_success cv_dev_require_stable_signing_text \
  $'Signature size=4797\nTeamIdentifier=TEAM123456\ndesignated => identifier "com.crispvoice.app" and anchor apple generic'
expect_failure cv_dev_require_stable_signing_text \
  $'Signature=adhoc\nTeamIdentifier=not set\ndesignated => cdhash H"1234"'
expect_failure cv_dev_require_stable_signing_text \
  $'Signature size=4797\nTeamIdentifier=TEAM123456\ndesignated => cdhash H"1234"'
expect_failure cv_dev_require_stable_signing_text \
  $'Signature size=4797\nTeamIdentifier=not set\ndesignated => identifier "com.crispvoice.app"'

fixture="$(mktemp -d -t crispvoice-dev-lib-tests)"
trap '/bin/rm -rf "$fixture"' EXIT
/bin/mkdir -p "$fixture/Expected.app/Contents/MacOS" "$fixture/Other.app/Contents/MacOS"
/usr/bin/touch "$fixture/Expected.app/Contents/MacOS/CrispVoiceExecutable"
/usr/bin/touch "$fixture/Other.app/Contents/MacOS/CrispVoice"
/usr/bin/touch "$fixture/Expected.app/Contents/Info.plist"
expected="$fixture/Expected.app/Contents/MacOS/CrispVoiceExecutable"
expect_success cv_dev_require_launched_path "$expected" "$expected"
expect_failure cv_dev_require_launched_path "$expected" "$fixture/Other.app/Contents/MacOS/CrispVoice"
expect_failure cv_dev_require_launched_path "$expected" "$expected --unexpected-argument"

fake_plutil="$fixture/plutil"
cat > "$fake_plutil" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == -extract && "$3" == raw && "$4" == -o && "$5" == - && $# -eq 6 ]] || exit 99
case "$2" in
  CFBundleIdentifier)
    [[ "${CV_TEST_BUNDLE_ID:-}" == wrong ]] && printf '%s\n' com.example.wrong || printf '%s\n' com.crispvoice.app
    ;;
  CFBundleExecutable)
    printf '%s\n' "${CV_TEST_EXECUTABLE-CrispVoiceExecutable}"
    ;;
  *) exit 98 ;;
esac
EOF
chmod +x "$fake_plutil"
bundle_executable="$(cv_dev_require_bundle "$fixture/Expected.app" com.crispvoice.app "$fake_plutil")" \
  || fail "bundle with distinct executable was rejected"
[[ "$bundle_executable" == "$expected" ]] || fail "bundle did not return CFBundleExecutable path"
if bundle_error="$(CV_TEST_BUNDLE_ID=wrong cv_dev_require_bundle "$fixture/Expected.app" com.crispvoice.app "$fake_plutil" 2>&1)"; then
  fail "bundle mismatch unexpectedly succeeded"
fi
[[ "$bundle_error" == *'Unexpected bundle identifier: com.example.wrong'* ]] || fail "bundle mismatch error"
for unsafe_executable in '' . .. ../outside; do
  if unsafe_executable_error="$(CV_TEST_EXECUTABLE="$unsafe_executable" cv_dev_require_bundle "$fixture/Expected.app" com.crispvoice.app "$fake_plutil" 2>&1)"; then
    fail "unsafe executable metadata unexpectedly succeeded: $unsafe_executable"
  fi
  [[ "$unsafe_executable_error" == *"Unsafe executable name: $unsafe_executable"* ]] \
    || fail "unsafe executable metadata error: $unsafe_executable"
done

fake_codesign="$fixture/codesign"
fake_shasum="$fixture/shasum"
export CV_TEST_EXPECTED_APP="$fixture/Expected.app"
cat > "$fake_codesign" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == --verify && "$2" == --deep && "$3" == --strict && "$4" == "$CV_TEST_EXPECTED_APP" && $# -eq 4 ]]; then exit 0; fi
if [[ "$1" == --display && "$2" == --verbose=4 && "$3" == --requirements && "$4" == - && "$5" == "$CV_TEST_EXPECTED_APP" && $# -eq 5 ]]; then
  printf '%s\n' 'Signature size=4797' 'TeamIdentifier=TEAM123456' 'designated => identifier "com.crispvoice.app" and anchor apple generic'
  exit 0
fi
if [[ "$1" == --display && "$2" == --extract-certificates=* && "${2#--extract-certificates=}" == */cert && "$3" == "$CV_TEST_EXPECTED_APP" && $# -eq 3 ]]; then
  touch "${2#--extract-certificates=}"0
  exit 0
fi
exit 97
EOF
cat > "$fake_shasum" <<'EOF'
#!/usr/bin/env bash
if [[ "${CV_TEST_CERT_SHA1:-expected}" == wrong ]]; then
  printf '%s\n' 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA  cert0'
else
  printf '%s\n' '151F66C8B0F20E6B0682394EEF7A3084495B50F1  cert0'
fi
EOF
chmod +x "$fake_codesign" "$fake_shasum"
expect_success cv_dev_require_signing "$fixture/Expected.app" 151F66C8B0F20E6B0682394EEF7A3084495B50F1 "$fake_codesign" "$fake_shasum"
if signing_error="$(CV_TEST_CERT_SHA1=wrong cv_dev_require_signing "$fixture/Expected.app" 151F66C8B0F20E6B0682394EEF7A3084495B50F1 "$fake_codesign" "$fake_shasum" 2>&1)"; then
  fail "certificate mismatch unexpectedly succeeded"
fi
[[ "$signing_error" == *'Signing certificate fingerprint did not match selected Apple Development identity'* ]] \
  || fail "certificate mismatch error"

echo "DevLaunchLibTests: PASS"
