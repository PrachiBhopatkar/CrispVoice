#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
fixture_root="$(mktemp -d -t crispvoice-run-dev-tests)"
trap '/bin/rm -rf "$fixture_root"' EXIT
fake_tools="$fixture_root/tools"
tool_log="$fixture_root/tools.log"
output_log="$fixture_root/output.log"
/bin/mkdir -p "$fake_tools"
/bin/mkdir -p "$fixture_root/Sources/CrispVoice/App"
cat > "$fixture_root/Sources/CrispVoice/App/CrispVoice.entitlements" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
EOF

fail() { echo "FAIL: $*" >&2; exit 1; }

cat > "$fake_tools/tool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
tool="$(basename "$0")"
scenario="$(cat "$CV_TEST_FIXTURE_ROOT/scenario")"
echo "$tool $*" >> "$CV_TEST_FIXTURE_ROOT/tools.log"
case "$tool" in
  security)
    case "$scenario" in
      no_identity) ;;
      multiple_identities)
        printf '%s\n' '  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Development: One (TEAMONE123)"'
        printf '%s\n' '  2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Apple Development: Two (TEAMTWO123)"'
        ;;
      *) printf '%s\n' '  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Development: Test (TEAMTEST123)"' ;;
    esac
    ;;
  xcodegen) exit 0 ;;
  xcodebuild)
    [[ "$scenario" != build_failure ]] || exit 1
    derived=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == -derivedDataPath ]]; then derived="$2"; shift 2; continue; fi
      shift
    done
    /bin/mkdir -p "$derived/Build/Products/Debug/CrispVoice.app/Contents/MacOS"
    /usr/bin/touch "$derived/Build/Products/Debug/CrispVoice.app/Contents/Info.plist"
    /usr/bin/touch "$derived/Build/Products/Debug/CrispVoice.app/Contents/MacOS/CrispVoice"
    ;;
  plutil)
    if [[ "$1" == -extract && "$2" == 'com\.apple\.security\.device\.audio-input' && "$3" == raw && "$4" == -expect && "$5" == bool && "$6" == -o && "$7" == - && $# -eq 8 ]]; then
      printf '%s\n' true
      exit 0
    fi
    [[ "$1" == -extract && "$3" == raw && "$4" == -o && "$5" == - && $# -eq 6 ]] || exit 99
    case "$2" in
      CFBundleIdentifier) [[ "$scenario" == wrong_bundle_id ]] && printf '%s\n' com.example.wrong || printf '%s\n' com.crispvoice.app ;;
      CFBundleExecutable) printf '%s\n' CrispVoice ;;
      *) exit 98 ;;
    esac
    ;;
  ditto)
    [[ "$scenario" != copy_failure ]] || exit 1
    /bin/cp -R "$1" "$2"
    ;;
  codesign)
    staged_app="$CV_TEST_FIXTURE_ROOT/DevBuild/.CrispVoice-stage."
    if [[ "$1" == --verify && "$2" == --deep && "$3" == --strict && "$4" == "$staged_app"*"/CrispVoice.app" && $# -eq 4 ]]; then
      [[ "$scenario" != strict_verification_failure ]] || exit 1
      exit 0
    fi
    if [[ "$1" == --display && "$2" == --verbose=4 && "$3" == --requirements && "$4" == - && "$5" == "$staged_app"*"/CrispVoice.app" && $# -eq 5 ]]; then
      if [[ "$scenario" == adhoc_signature ]]; then
        printf '%s\n' 'Signature=adhoc' 'TeamIdentifier=not set' 'designated => cdhash H"1234"'
      else
        printf '%s\n' 'Signature size=4797' 'flags=0x10000(runtime)' 'TeamIdentifier=TEAMTEST123' 'designated => identifier "com.crispvoice.app" and anchor apple generic'
      fi
      exit 0
    fi
    if [[ "$1" == --display && "$2" == --entitlements && "$3" == */entitlements.plist && "$4" == --xml && "$5" == "$staged_app"*"/CrispVoice.app" && $# -eq 5 ]]; then
      printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<plist version="1.0"><dict><key>com.apple.security.device.audio-input</key><true/></dict></plist>' > "$3"
      exit 0
    fi
    if [[ "$1" == --display && "$2" == --extract-certificates=* && "${2#--extract-certificates=}" == */cert && "$3" == "$staged_app"*"/CrispVoice.app" && $# -eq 3 ]]; then
      /usr/bin/touch "${2#--extract-certificates=}"0
      exit 0
    fi
    if [[ "$1" == --force && "$2" == --deep && "$3" == --sign && "$4" == AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA && "$5" == --options && "$6" == runtime && "$7" == --entitlements && "$8" == "$CV_TEST_FIXTURE_ROOT/Sources/CrispVoice/App/CrispVoice.entitlements" && "$9" == "$staged_app"*"/CrispVoice.app" && $# -eq 9 ]]; then
      [[ "$scenario" != sign_failure ]] || exit 1
      exit 0
    fi
    exit 97
    ;;
  shasum)
    [[ "$scenario" == wrong_certificate ]] && printf '%s\n' 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB  cert0' || printf '%s\n' 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA  cert0'
    ;;
  id) printf '%s\n' 501 ;;
  pgrep)
    [[ -f "$CV_TEST_FIXTURE_ROOT/launched" ]] || exit 1
    [[ "$scenario" != launch_failure && "$scenario" != rollback_restore_failure ]] || exit 1
    printf '%s\n' 123
    ;;
  ps)
    if [[ "$scenario" == wrong_launched_path ]]; then
      printf '%s\n' "$CV_TEST_FIXTURE_ROOT/Other.app/Contents/MacOS/CrispVoice"
    else
      printf '%s\n' "$CV_TEST_FIXTURE_ROOT/DevBuild/CrispVoice.app/Contents/MacOS/CrispVoice"
    fi
    ;;
  killall) exit 0 ;;
  open) /usr/bin/touch "$CV_TEST_FIXTURE_ROOT/launched" ;;
  sleep) exit 0 ;;
  mktemp) /usr/bin/mktemp "$@" ;;
  mv)
    if [[ "$scenario" == rollback_restore_failure && "$1" == *"/.CrispVoice-backup."*"/CrispVoice.app" && "$2" == "$CV_TEST_FIXTURE_ROOT/DevBuild/CrispVoice.app" ]]; then
      exit 1
    fi
    /bin/mv "$@"
    ;;
  rm) /bin/rm "$@" ;;
  mkdir) /bin/mkdir "$@" ;;
  *) echo "unexpected fake tool: $tool" >&2; exit 1 ;;
esac
EOF
chmod +x "$fake_tools/tool"
for tool in xcodegen xcodebuild security codesign plutil shasum ditto pgrep ps id killall open mktemp mv rm mkdir sleep; do
  /bin/ln -s tool "$fake_tools/$tool"
done

run_launcher() {
  local scenario="$1"
  printf '%s\n' "$scenario" > "$fixture_root/scenario"
  /bin/rm -f "$fixture_root/launched" "$tool_log" "$output_log"
  /bin/rm -rf "$fixture_root/.build"
  /bin/mkdir -p "$fixture_root/DevBuild/CrispVoice.app"
  printf '%s\n' prior > "$fixture_root/DevBuild/CrispVoice.app/marker"
  if CV_TEST_FIXTURE_ROOT="$fixture_root" \
    CRISPVOICE_DEV_LAUNCHER_TEST_MODE=1 \
    CRISPVOICE_DEV_ROOT_OVERRIDE="$fixture_root" \
    CRISPVOICE_DEV_TOOL_DIR="$fake_tools" \
    CRISPVOICE_DEV_LAUNCH_TIMEOUT_ATTEMPTS=2 \
      /bin/bash "$ROOT_DIR/scripts/run-dev.sh" >"$output_log" 2>&1; then
    return 0
  fi
  return 1
}

run_preflight_without_stable() {
  local scenario="$1"
  printf '%s\n' "$scenario" > "$fixture_root/scenario"
  /bin/rm -f "$fixture_root/launched" "$tool_log" "$output_log"
  /bin/rm -rf "$fixture_root/.build" "$fixture_root/DevBuild"
  if CV_TEST_FIXTURE_ROOT="$fixture_root" \
    CRISPVOICE_DEV_LAUNCHER_TEST_MODE=1 \
    CRISPVOICE_DEV_ROOT_OVERRIDE="$fixture_root" \
    CRISPVOICE_DEV_TOOL_DIR="$fake_tools" \
    CRISPVOICE_DEV_LAUNCH_TIMEOUT_ATTEMPTS=2 \
      /bin/bash "$ROOT_DIR/scripts/run-dev.sh" >"$output_log" 2>&1; then
    return 0
  fi
  return 1
}

run_launcher success || fail "success scenario failed"
[[ -d "$fixture_root/DevBuild/CrispVoice.app" ]] || fail "stable app missing after success"
/usr/bin/grep -Fq "$fixture_root/.build/DerivedData" "$tool_log" || fail "local DerivedData path not used"
/usr/bin/grep -Fq "$fixture_root/DevBuild/CrispVoice.app" "$output_log" || fail "stable app path not printed"
! /usr/bin/grep -Fq "$HOME/Library/Developer/Xcode/DerivedData" "$tool_log" || fail "global DerivedData was used"

for scenario in no_identity multiple_identities build_failure copy_failure sign_failure strict_verification_failure adhoc_signature wrong_bundle_id wrong_certificate; do
  if run_launcher "$scenario"; then fail "$scenario unexpectedly succeeded"; fi
  [[ "$(cat "$fixture_root/DevBuild/CrispVoice.app/marker")" == prior ]] || fail "$scenario changed prior app"
  ! /usr/bin/grep -Fq 'killall ' "$tool_log" || fail "$scenario killed a running app"
  ! /usr/bin/grep -Fq 'open ' "$tool_log" || fail "$scenario opened an app"
done

for scenario in no_identity multiple_identities; do
  if run_preflight_without_stable "$scenario"; then fail "$scenario without a stable app unexpectedly succeeded"; fi
  [[ ! -e "$fixture_root/DevBuild" && ! -L "$fixture_root/DevBuild" ]] || fail "$scenario created DevBuild before identity preflight"
  ! /usr/bin/grep -Fq 'killall ' "$tool_log" || fail "$scenario without a stable app killed a running app"
  ! /usr/bin/grep -Fq 'open ' "$tool_log" || fail "$scenario without a stable app opened an app"
done

for scenario in launch_failure wrong_launched_path; do
  if run_launcher "$scenario"; then fail "$scenario unexpectedly succeeded"; fi
  [[ "$(cat "$fixture_root/DevBuild/CrispVoice.app/marker")" == prior ]] || fail "$scenario did not restore prior app"
done

if run_launcher rollback_restore_failure; then fail "rollback_restore_failure unexpectedly succeeded"; fi
backup_path="$(find "$fixture_root/DevBuild" -maxdepth 1 -type d -name '.CrispVoice-backup.*' -print -quit)"
[[ -n "$backup_path" ]] || fail "rollback restore failure deleted backup"
[[ "$(cat "$backup_path/CrispVoice.app/marker")" == prior ]] || fail "retained backup is not recoverable"
/usr/bin/grep -Fq "backup retained at: $backup_path/CrispVoice.app" "$output_log" || fail "retained backup path not reported"

/bin/rm -f "$tool_log"
if CRISPVOICE_DEV_ROOT_OVERRIDE="$fixture_root" /bin/bash "$ROOT_DIR/scripts/run-dev.sh" >/dev/null 2>&1; then
  fail "unguarded override unexpectedly succeeded"
fi
[[ ! -f "$tool_log" ]] || fail "unguarded override ran fake tools"

echo "RunDevTests: PASS"
