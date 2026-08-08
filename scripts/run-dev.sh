#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/dev-launch-lib.sh"

test_mode="${CRISPVOICE_DEV_LAUNCHER_TEST_MODE:-}"
for test_variable in CRISPVOICE_DEV_ROOT_OVERRIDE CRISPVOICE_DEV_TOOL_DIR CRISPVOICE_DEV_LAUNCH_TIMEOUT_ATTEMPTS; do
  if [[ "$test_mode" != "1" && -n "${!test_variable+x}" ]]; then
    cv_dev_die "$test_variable is allowed only with CRISPVOICE_DEV_LAUNCHER_TEST_MODE=1"
  fi
done
if [[ -n "${CRISPVOICE_DEV_LAUNCHER_TEST_MODE+x}" && "$test_mode" != "1" ]]; then
  cv_dev_die "CRISPVOICE_DEV_LAUNCHER_TEST_MODE must be exactly 1 when set"
fi

if [[ "$test_mode" == "1" ]]; then
  [[ -n "${CRISPVOICE_DEV_ROOT_OVERRIDE:-}" && -n "${CRISPVOICE_DEV_TOOL_DIR:-}" ]] \
    || cv_dev_die "Test mode requires CRISPVOICE_DEV_ROOT_OVERRIDE and CRISPVOICE_DEV_TOOL_DIR"
  ROOT_DIR="$(cd "$CRISPVOICE_DEV_ROOT_OVERRIDE" && pwd)"
  TOOL_DIR="$CRISPVOICE_DEV_TOOL_DIR"
  LAUNCH_TIMEOUT_ATTEMPTS="${CRISPVOICE_DEV_LAUNCH_TIMEOUT_ATTEMPTS:-10}"
  [[ "$LAUNCH_TIMEOUT_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] \
    || cv_dev_die "CRISPVOICE_DEV_LAUNCH_TIMEOUT_ATTEMPTS must be a positive integer"
else
  ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
  TOOL_DIR=""
  LAUNCH_TIMEOUT_ATTEMPTS=10
fi

APP_NAME="CrispVoice.app"
BUNDLE_ID="com.crispvoice.app"
DERIVED_DATA="$ROOT_DIR/.build/DerivedData"
SOURCE_APP="$DERIVED_DATA/Build/Products/Debug/$APP_NAME"
STABLE_DIR="$ROOT_DIR/DevBuild"
STABLE_APP="$STABLE_DIR/$APP_NAME"
EXPECTED_EXECUTABLE="$STABLE_APP/Contents/MacOS/CrispVoice"
ENTITLEMENTS_PATH="$ROOT_DIR/Sources/CrispVoice/App/CrispVoice.entitlements"

if [[ "$test_mode" == "1" ]]; then
  XCODEGEN_BIN="$TOOL_DIR/xcodegen"
  XCODEBUILD_BIN="$TOOL_DIR/xcodebuild"
  SECURITY_BIN="$TOOL_DIR/security"
  CODESIGN_BIN="$TOOL_DIR/codesign"
  PLUTIL_BIN="$TOOL_DIR/plutil"
  SHASUM_BIN="$TOOL_DIR/shasum"
  DITTO_BIN="$TOOL_DIR/ditto"
  PGREP_BIN="$TOOL_DIR/pgrep"
  PS_BIN="$TOOL_DIR/ps"
  ID_BIN="$TOOL_DIR/id"
  KILLALL_BIN="$TOOL_DIR/killall"
  OPEN_BIN="$TOOL_DIR/open"
  MKTEMP_BIN="$TOOL_DIR/mktemp"
  MV_BIN="$TOOL_DIR/mv"
  RM_BIN="$TOOL_DIR/rm"
  MKDIR_BIN="$TOOL_DIR/mkdir"
  SLEEP_BIN="$TOOL_DIR/sleep"
else
  XCODEGEN_BIN="$(/usr/bin/command -v xcodegen || true)"
  XCODEBUILD_BIN="/usr/bin/xcodebuild"
  SECURITY_BIN="/usr/bin/security"
  CODESIGN_BIN="/usr/bin/codesign"
  PLUTIL_BIN="/usr/bin/plutil"
  SHASUM_BIN="/usr/bin/shasum"
  DITTO_BIN="/usr/bin/ditto"
  PGREP_BIN="/usr/bin/pgrep"
  PS_BIN="/bin/ps"
  ID_BIN="/usr/bin/id"
  KILLALL_BIN="/usr/bin/killall"
  OPEN_BIN="/usr/bin/open"
  MKTEMP_BIN="/usr/bin/mktemp"
  MV_BIN="/bin/mv"
  RM_BIN="/bin/rm"
  MKDIR_BIN="/bin/mkdir"
  SLEEP_BIN="/bin/sleep"
fi

for required_tool in "$XCODEGEN_BIN" "$XCODEBUILD_BIN" "$SECURITY_BIN" "$CODESIGN_BIN" "$PLUTIL_BIN" "$SHASUM_BIN" "$DITTO_BIN" "$PGREP_BIN" "$PS_BIN" "$ID_BIN" "$KILLALL_BIN" "$OPEN_BIN" "$MKTEMP_BIN" "$MV_BIN" "$RM_BIN" "$MKDIR_BIN" "$SLEEP_BIN"; do
  [[ -x "$required_tool" ]] || cv_dev_die "Required tool is unavailable: $required_tool"
done

[[ -d "$ROOT_DIR" && ! -L "$ROOT_DIR" ]] || cv_dev_die "Repository root must be a real directory"
[[ -f "$ENTITLEMENTS_PATH" && ! -L "$ENTITLEMENTS_PATH" ]] \
  || cv_dev_die "Audio Input entitlement file is missing or invalid."

staging_dir=""
backup_dir=""
replacement_started=0
launch_verified=0
had_previous=0

cleanup() {
  local exit_status="$?"
  local backup_app=""
  local restore_failed=0

  if [[ "$launch_verified" -ne 1 && "$replacement_started" -eq 1 ]]; then
    if [[ -d "$STABLE_APP" && ! -L "$STABLE_APP" ]]; then
      "$RM_BIN" -rf "$STABLE_APP" || restore_failed=1
    fi
    if [[ "$had_previous" -eq 1 ]]; then
      backup_app="$backup_dir/$APP_NAME"
      if [[ "$restore_failed" -eq 0 && -d "$backup_app" && ! -L "$backup_app" && ! -e "$STABLE_APP" && ! -L "$STABLE_APP" ]]; then
        "$MV_BIN" "$backup_app" "$STABLE_APP" || restore_failed=1
      else
        restore_failed=1
      fi
      if [[ "$restore_failed" -eq 1 ]]; then
        printf 'Error: Failed to restore previous stable app; backup retained at: %s\n' "$backup_app" >&2
        backup_dir=""
        exit_status=1
      fi
    fi
  fi
  if [[ -n "$staging_dir" && -d "$staging_dir" && ! -L "$staging_dir" ]]; then
    "$RM_BIN" -rf "$staging_dir" || true
  fi
  if [[ -n "$backup_dir" && -d "$backup_dir" && ! -L "$backup_dir" ]]; then
    "$RM_BIN" -rf "$backup_dir" || true
  fi
  exit "$exit_status"
}
trap cleanup EXIT

identity_output="$("$SECURITY_BIN" find-identity -v -p codesigning)" \
  || cv_dev_die "Could not read code-signing identities from the login Keychain"
selected_identity="$(cv_dev_require_single_identity "$identity_output")" || exit 1
selected_sha1="${selected_identity%%$'\t'*}"
selected_name="${selected_identity#*$'\t'}"

if [[ -e "$STABLE_DIR" || -L "$STABLE_DIR" ]]; then
  [[ -d "$STABLE_DIR" && ! -L "$STABLE_DIR" ]] || cv_dev_die "Stable development directory must not be a symlink"
else
  "$MKDIR_BIN" -p "$STABLE_DIR"
fi
[[ -d "$STABLE_DIR" && ! -L "$STABLE_DIR" ]] || cv_dev_die "Could not create stable development directory"
if [[ -e "$STABLE_APP" || -L "$STABLE_APP" ]]; then
  [[ -d "$STABLE_APP" && ! -L "$STABLE_APP" ]] || cv_dev_die "Stable development app must not be a symlink"
fi

cd "$ROOT_DIR"
"$XCODEGEN_BIN" generate
"$XCODEBUILD_BIN" -project CrispVoice.xcodeproj -scheme CrispVoice -configuration Debug -derivedDataPath "$DERIVED_DATA" build

cv_dev_require_bundle "$SOURCE_APP" "$BUNDLE_ID" "$PLUTIL_BIN" >/dev/null

staging_dir="$("$MKTEMP_BIN" -d "$STABLE_DIR/.CrispVoice-stage.XXXXXX")"
[[ -d "$staging_dir" && ! -L "$staging_dir" ]] || cv_dev_die "Staging directory must be a real private directory"
staged_app="$staging_dir/$APP_NAME"
"$DITTO_BIN" "$SOURCE_APP" "$staged_app"
[[ -d "$staged_app" && ! -L "$staged_app" ]] || cv_dev_die "Staged app must be a real directory"

# Sign standard nested code from the inside out. Application-only entitlements
# belong on the outer app signature and must never propagate to nested code.
nested_candidates="$staging_dir/nested-code.txt"
: > "$nested_candidates"

{
  for relative_root in Frameworks PlugIns XPCServices Helpers; do
    search_root="$staged_app/Contents/$relative_root"
    [[ -d "$search_root" ]] || continue

    /usr/bin/find -P "$search_root" \
      \( -type d \( -name '*.app' -o -name '*.appex' -o -name '*.bundle' -o -name '*.framework' -o -name '*.plugin' -o -name '*.xpc' \) -o -type f \) \
      -print \
      | while IFS= read -r candidate; do
          if [[ -d "$candidate" ]]; then
            printf '%s\n' "$candidate"
          elif [[ ! -L "$candidate" ]] && /usr/bin/file -b "$candidate" | /usr/bin/grep -q '^Mach-O'; then
            printf '%s\n' "$candidate"
          fi
        done
  done

  macos_root="$staged_app/Contents/MacOS"
  if [[ -d "$macos_root" ]]; then
    /usr/bin/find -P "$macos_root" -type f -print \
      | while IFS= read -r candidate; do
          if [[ "$candidate" != "$staged_app/Contents/MacOS/CrispVoice" && ! -L "$candidate" ]] \
            && /usr/bin/file -b "$candidate" | /usr/bin/grep -q '^Mach-O'; then
            printf '%s\n' "$candidate"
          fi
        done
  fi
} \
  | /usr/bin/awk '{ print length($0) "\t" $0 }' \
  | /usr/bin/sort -rn \
  | /usr/bin/cut -f2- \
  | /usr/bin/awk '!seen[$0]++' \
  > "$nested_candidates"

while IFS= read -r candidate; do
  [[ -n "$candidate" && -e "$candidate" ]] || continue
  "$CODESIGN_BIN" \
    --force \
    --sign "$selected_sha1" \
    --options runtime \
    "$candidate"
done < "$nested_candidates"

"$CODESIGN_BIN" \
  --force \
  --sign "$selected_sha1" \
  --options runtime \
  --entitlements "$ENTITLEMENTS_PATH" \
  "$staged_app"
cv_dev_require_bundle "$staged_app" "$BUNDLE_ID" "$PLUTIL_BIN" >/dev/null
cv_dev_require_signing "$staged_app" "$selected_sha1" "$CODESIGN_BIN" "$SHASUM_BIN" "$PLUTIL_BIN"

current_uid="$("$ID_BIN" -u)"
running_pids=""
if running_pids="$("$PGREP_BIN" -u "$current_uid" -x CrispVoice)"; then
  :
else
  pgrep_status=$?
  [[ "$pgrep_status" -eq 1 ]] || cv_dev_die "Could not inspect current-user CrispVoice processes"
fi
if [[ -n "$running_pids" ]]; then
  "$KILLALL_BIN" CrispVoice
  for ((stop_attempt=1; stop_attempt<=LAUNCH_TIMEOUT_ATTEMPTS; stop_attempt++)); do
    if "$PGREP_BIN" -u "$current_uid" -x CrispVoice >/dev/null 2>&1; then
      "$SLEEP_BIN" 1
    else
      pgrep_status=$?
      [[ "$pgrep_status" -eq 1 ]] || cv_dev_die "Could not confirm current-user CrispVoice shutdown"
      break
    fi
    [[ "$stop_attempt" -lt "$LAUNCH_TIMEOUT_ATTEMPTS" ]] || cv_dev_die "Timed out waiting for current-user CrispVoice to stop"
  done
fi

if [[ -d "$STABLE_APP" ]]; then
  had_previous=1
  backup_dir="$("$MKTEMP_BIN" -d "$STABLE_DIR/.CrispVoice-backup.XXXXXX")"
  [[ -d "$backup_dir" && ! -L "$backup_dir" ]] || cv_dev_die "Backup directory must be a real private directory"
  "$MV_BIN" "$STABLE_APP" "$backup_dir/$APP_NAME"
fi
replacement_started=1
"$MV_BIN" "$staged_app" "$STABLE_APP"

"$OPEN_BIN" "$STABLE_APP"
for ((launch_attempt=1; launch_attempt<=LAUNCH_TIMEOUT_ATTEMPTS; launch_attempt++)); do
  launched_pids=""
  if launched_pids="$("$PGREP_BIN" -u "$current_uid" -x CrispVoice)"; then
    while IFS= read -r launched_pid; do
      [[ -n "$launched_pid" ]] || continue
      launched_command="$("$PS_BIN" -p "$launched_pid" -o command=)" || continue
      if cv_dev_require_launched_path "$EXPECTED_EXECUTABLE" "$launched_command"; then
        launch_verified=1
        break 2
      fi
    done <<< "$launched_pids"
  else
    pgrep_status=$?
    [[ "$pgrep_status" -eq 1 ]] || cv_dev_die "Could not inspect launched CrispVoice process"
  fi
  "$SLEEP_BIN" 1
done
[[ "$launch_verified" -eq 1 ]] || cv_dev_die "CrispVoice did not launch from the stable development copy"

if [[ -n "$backup_dir" && -d "$backup_dir" && ! -L "$backup_dir" ]]; then
  "$RM_BIN" -rf "$backup_dir"
  backup_dir=""
fi
stable_physical_path="$(cv_dev_physical_path "$STABLE_APP")"
printf 'Launched stable dev build: %s\n' "$stable_physical_path"
printf 'Signing identity: %s\n' "$selected_name"
