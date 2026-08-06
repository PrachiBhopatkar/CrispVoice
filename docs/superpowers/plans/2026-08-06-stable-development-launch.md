# Stable Development Launch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Guarantee that terminal and coding-agent development launches always run the verified, certificate-signed `DevBuild/CrispVoice.app` copy and never an ad-hoc app from Xcode DerivedData.

**Architecture:** `scripts/run-dev.sh` becomes a fail-closed build, stage, sign, verify, replace, launch, and process-path verification pipeline. It builds into repository-local `.build/DerivedData`, uses exactly one valid Apple Development identity from the login Keychain, preserves the last working stable app until the new process is verified, and exposes guarded test-only command overrides so rollback and rejection paths can be integration-tested without changing the real app or Keychain.

**Tech Stack:** Bash 3.2, XcodeGen, `xcodebuild`, macOS `security`, `codesign`, `plutil`, `ditto`, `pgrep`, `ps`, `open`, XCTest.

## Global Constraints

- `./scripts/run-dev.sh` is the single supported terminal and coding-agent development launcher.
- Direct Xcode Run support is out of scope.
- Build products must come only from `.build/DerivedData/Build/Products/Debug/CrispVoice.app`.
- The launched app must be `DevBuild/CrispVoice.app` with bundle identifier `com.crispvoice.app`.
- Require exactly one valid identity whose display name begins with `Apple Development:`.
- Never launch an ad-hoc signature or a designated requirement containing `cdhash`.
- Never fall back to ad-hoc signing.
- Do not reset TCC, modify macOS privacy databases, or change Keychain trust settings.
- Do not commit private keys, certificate passwords, generated apps, or machine-specific identity fingerprints.
- Preserve unrelated working-tree changes, including `docs/superpowers/plans/2026-07-05-formalize-tone.md` and `.dev/`.
- Keep App Sandbox disabled and preserve CrispVoice's no-backend privacy model.
- Run the full XCTest suite and Debug build after the task.
- Commit only after automated checks and the manual stable-launch verification pass.

## File Structure

- `scripts/dev-launch-lib.sh` — Bash 3.2 parsing and validation functions that do not launch or mutate applications.
- `scripts/run-dev.sh` — orchestrates preflight, deterministic build, staging, signing, verification, rollback, launch, and process-path validation.
- `Tests/DevScripts/DevLaunchLibTests.sh` — unit tests for identity parsing, signing-info validation, bundle metadata, and path comparison.
- `Tests/DevScripts/RunDevTests.sh` — integration tests using a private fixture root and fake system commands for preflight, rollback, and launch behavior.
- `AGENTS.md` — replaces the contradictory DerivedData launch instructions with the canonical launcher.
- `README.md` — states that the stable launcher is required for permission continuity and direct Xcode Run is out of scope.

---

### Task 1: Make the Stable Development Launcher Mandatory and Fail Closed

**Files:**
- Create: `scripts/dev-launch-lib.sh`
- Create: `Tests/DevScripts/DevLaunchLibTests.sh`
- Create: `Tests/DevScripts/RunDevTests.sh`
- Modify: `scripts/run-dev.sh`
- Modify: `AGENTS.md:91-94`
- Modify: `README.md:205-220`

**Interfaces:**
- `cv_dev_die MESSAGE` — prints `Error: MESSAGE` to stderr and returns nonzero by exiting the caller.
- `cv_dev_parse_apple_identity_lines` — reads `security find-identity` output from stdin and writes `SHA1<TAB>DISPLAY_NAME` for every valid `Apple Development:` identity.
- `cv_dev_require_single_identity SECURITY_OUTPUT` — writes exactly one `SHA1<TAB>DISPLAY_NAME`; fails for zero or multiple matches.
- `cv_dev_require_bundle APP_PATH EXPECTED_BUNDLE_ID PLUTIL_BIN` — validates a real app directory, regular `Info.plist`, safe executable name, regular executable, and exact bundle identifier; writes the executable path.
- `cv_dev_require_signing APP_PATH EXPECTED_SHA1 CODESIGN_BIN SHASUM_BIN` — requires strict code-signature verification, a leaf certificate with the selected fingerprint, a non-ad-hoc signature, a non-empty Team Identifier, and a designated requirement that does not contain `cdhash`.
- `cv_dev_physical_path PATH` — writes the normalized physical path for an existing file or directory.
- `cv_dev_require_launched_path EXPECTED_EXECUTABLE ACTUAL_COMMAND` — compares normalized executable paths and rejects arguments or a different app path.
- Test mode is enabled only by `CRISPVOICE_DEV_LAUNCHER_TEST_MODE=1`. Only in that mode may `CRISPVOICE_DEV_ROOT_OVERRIDE`, `CRISPVOICE_DEV_TOOL_DIR`, and `CRISPVOICE_DEV_LAUNCH_TIMEOUT_ATTEMPTS` affect behavior. Any of those variables outside test mode is an error.
- Production output ends with both `Launched stable dev build: <physical app path>` and `Signing identity: <Apple Development display name>`.

- [ ] **Step 1: Write failing unit tests for the pure validation library**

Create `Tests/DevScripts/DevLaunchLibTests.sh` with Bash 3.2-compatible helpers and these exact assertions:

```bash
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
/usr/bin/touch "$fixture/Expected.app/Contents/MacOS/CrispVoice"
/usr/bin/touch "$fixture/Other.app/Contents/MacOS/CrispVoice"
expected="$fixture/Expected.app/Contents/MacOS/CrispVoice"
expect_success cv_dev_require_launched_path "$expected" "$expected"
expect_failure cv_dev_require_launched_path "$expected" "$fixture/Other.app/Contents/MacOS/CrispVoice"
expect_failure cv_dev_require_launched_path "$expected" "$expected --unexpected-argument"

echo "DevLaunchLibTests: PASS"
```

The test may add focused fixture commands for `cv_dev_require_bundle` and `cv_dev_require_signing` using fake `plutil`, `codesign`, and `shasum` executables. It must assert the exact bundle-ID mismatch and certificate-fingerprint mismatch paths, not merely invoke them.

- [ ] **Step 2: Run the unit test and confirm the intended failure**

Run:

```bash
/bin/bash Tests/DevScripts/DevLaunchLibTests.sh
```

Expected: FAIL because `scripts/dev-launch-lib.sh` does not exist.

- [ ] **Step 3: Implement the focused Bash validation library**

Create `scripts/dev-launch-lib.sh` with no top-level mutations and the following implementation boundaries:

```bash
#!/usr/bin/env bash

cv_dev_die() {
  echo "Error: $*" >&2
  return 1
}

cv_dev_parse_apple_identity_lines() {
  /usr/bin/sed -n \
    's/^[[:space:]]*[0-9][0-9]*) \([0-9A-F][0-9A-F]*\) "\(Apple Development:[^"]*\)".*$/\1\	\2/p'
}

cv_dev_require_single_identity() {
  local security_output="$1"
  local parsed
  local count
  parsed="$(printf '%s\n' "$security_output" | cv_dev_parse_apple_identity_lines)" || return 1
  count="$(printf '%s\n' "$parsed" | /usr/bin/awk 'NF { count++ } END { print count+0 }')"
  [[ "$count" == "1" ]] || {
    echo "Expected exactly one valid Apple Development signing identity; found $count." >&2
    return 1
  }
  printf '%s\n' "$parsed"
}

cv_dev_require_stable_signing_text() {
  local signing_text="$1"
  printf '%s\n' "$signing_text" | /usr/bin/grep -Fq 'Signature=adhoc' && return 1
  printf '%s\n' "$signing_text" | /usr/bin/grep -Eq '^TeamIdentifier=.+$' || return 1
  printf '%s\n' "$signing_text" | /usr/bin/grep -Fq 'TeamIdentifier=not set' && return 1
  printf '%s\n' "$signing_text" | /usr/bin/grep -Eq '^designated => .+' || return 1
  printf '%s\n' "$signing_text" | /usr/bin/grep -Fq 'cdhash ' && return 1
}
```

Complete the remaining declared functions using quoted paths and system Bash 3.2 syntax. `cv_dev_require_bundle` must use `plutil -extract ... raw -o -`; `cv_dev_require_signing` must capture `codesign --display --verbose=4 --requirements -`, extract certificate zero into a private temporary directory, compare the uppercase DER SHA-1 with `EXPECTED_SHA1`, and remove its temporary directory on every return. `cv_dev_require_launched_path` must reject whitespace-delimited arguments and compare physical paths without using `realpath`, which is not guaranteed on the minimum supported macOS.

- [ ] **Step 4: Run the unit test and confirm it passes**

Run:

```bash
/bin/bash -n scripts/dev-launch-lib.sh
/bin/bash Tests/DevScripts/DevLaunchLibTests.sh
```

Expected: syntax check succeeds and `DevLaunchLibTests: PASS`.

- [ ] **Step 5: Write failing integration tests for orchestration and rollback**

Create `Tests/DevScripts/RunDevTests.sh`. It must create a private fixture root and fake tool directory, copy `scripts/run-dev.sh` and `scripts/dev-launch-lib.sh` into the fixture, and invoke the launcher only with:

```bash
CRISPVOICE_DEV_LAUNCHER_TEST_MODE=1 \
CRISPVOICE_DEV_ROOT_OVERRIDE="$fixture_root" \
CRISPVOICE_DEV_TOOL_DIR="$fake_tools" \
CRISPVOICE_DEV_LAUNCH_TIMEOUT_ATTEMPTS=2 \
  /bin/bash "$ROOT_DIR/scripts/run-dev.sh"
```

The fake tools must log invocations and be controlled by a single `CV_TEST_SCENARIO` value. Implement and assert all of these scenarios:

```text
success
no_identity
multiple_identities
build_failure
sign_failure
adhoc_signature
wrong_bundle_id
wrong_certificate
launch_failure
wrong_launched_path
```

For `success`, assert that:

```bash
[[ -d "$fixture_root/DevBuild/CrispVoice.app" ]]
/usr/bin/grep -Fq "$fixture_root/.build/DerivedData" "$tool_log"
/usr/bin/grep -Fq "$fixture_root/DevBuild/CrispVoice.app" "$output_log"
! /usr/bin/grep -Fq "$HOME/Library/Developer/Xcode/DerivedData" "$tool_log"
```

For every preflight scenario through `wrong_certificate`, place a marker in the prior stable app and assert the marker is unchanged and the fake `killall` and `open` tools were never called. For `launch_failure` and `wrong_launched_path`, assert the prior marker is restored after the launcher exits nonzero. Also invoke the launcher once with `CRISPVOICE_DEV_ROOT_OVERRIDE` set but without `CRISPVOICE_DEV_LAUNCHER_TEST_MODE=1` and assert it fails before any fake tool runs.

- [ ] **Step 6: Run the integration test and confirm the intended failure**

Run:

```bash
/bin/bash Tests/DevScripts/RunDevTests.sh
```

Expected: FAIL because the current launcher searches global DerivedData, permits ad-hoc fallback, and has no guarded fake-tool interface or rollback verification.

- [ ] **Step 7: Implement the fail-closed launcher orchestration**

Rewrite `scripts/run-dev.sh` around these exact production constants:

```bash
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="CrispVoice.app"
BUNDLE_ID="com.crispvoice.app"
DERIVED_DATA="$ROOT_DIR/.build/DerivedData"
SOURCE_APP="$DERIVED_DATA/Build/Products/Debug/$APP_NAME"
STABLE_DIR="$ROOT_DIR/DevBuild"
STABLE_APP="$STABLE_DIR/$APP_NAME"
EXPECTED_EXECUTABLE="$STABLE_APP/Contents/MacOS/CrispVoice"
```

Source `scripts/dev-launch-lib.sh`, use `set -euo pipefail`, validate test-mode variables before resolving command paths, and use absolute system tools in production. The test tool directory must provide exact executable names matching the production tools. Require `xcodegen`, `xcodebuild`, `security`, `codesign`, `plutil`, `shasum`, `ditto`, `pgrep`, `ps`, `id`, `killall`, `open`, `mktemp`, `mv`, `rm`, `mkdir`, and `sleep`.

Implement the approved flow in this order:

```text
identity preflight
xcodegen generate
xcodebuild Debug with -derivedDataPath
exact SOURCE_APP validation
private staging directory
ditto SOURCE_APP to staged CrispVoice.app
codesign --force --deep --sign SELECTED_SHA1 staged app
bundle and stable-signature verification
stop the current user's CrispVoice process if present
backup existing STABLE_APP
move staged app to STABLE_APP
open STABLE_APP
bounded pgrep/ps polling for EXPECTED_EXECUTABLE
commit replacement by deleting backup
print physical stable path and identity
```

Use a cleanup trap with explicit `replacement_started`, `launch_verified`, and `had_previous` flags. Before launch verification, cleanup removes the failed new stable app and restores the backup. Do not delete or overwrite a real directory through an unresolved environment variable or symlink. Reject a symlinked `STABLE_DIR`, `STABLE_APP`, staging directory, or backup.

When stopping CrispVoice, scope `pgrep` to the current UID. Treat `pgrep` status `1` as "not running" and any other nonzero status as an error. After `killall`, poll until no current-user CrispVoice process remains before replacing the app. During launch verification, compare each current-user CrispVoice process command with the normalized expected executable and fail if no exact match appears within the configured attempt count.

- [ ] **Step 8: Run all launcher tests and fix only failures in this task's scope**

Run:

```bash
/bin/bash -n scripts/dev-launch-lib.sh
/bin/bash -n scripts/run-dev.sh
/bin/bash -n Tests/DevScripts/DevLaunchLibTests.sh
/bin/bash -n Tests/DevScripts/RunDevTests.sh
/bin/bash Tests/DevScripts/DevLaunchLibTests.sh
/bin/bash Tests/DevScripts/RunDevTests.sh
```

Expected: all syntax checks succeed and both test scripts print `PASS`.

- [ ] **Step 9: Replace contradictory operational documentation**

In `AGENTS.md`, replace the DerivedData `find` and `open` commands with:

```bash
# Build, sign, verify, and launch the stable development copy.
./scripts/run-dev.sh
```

Add one sentence immediately below: `Do not launch CrispVoice directly from Xcode DerivedData; that build is ad-hoc signed and invalidates Accessibility permission after rebuilds.`

In the README development section, retain `./scripts/run-dev.sh` and add: `This is the supported development launch path. It signs and opens DevBuild/CrispVoice.app so macOS can preserve Accessibility permission across rebuilds; direct Xcode Run is not covered by this workflow.`

- [ ] **Step 10: Run task-specific, full-suite, and build verification**

Run:

```bash
/bin/bash Tests/DevScripts/DevLaunchLibTests.sh
/bin/bash Tests/DevScripts/RunDevTests.sh
xcodegen generate
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -configuration Debug build
```

Expected: both shell suites pass, all XCTest cases pass, and the build ends with `** BUILD SUCCEEDED **`.

- [ ] **Step 11: Perform the live two-launch identity and Accessibility verification**

Run:

```bash
./scripts/run-dev.sh
/usr/bin/codesign -d --verbose=4 --requirements - DevBuild/CrispVoice.app 2>&1
./scripts/run-dev.sh
/usr/bin/codesign -d --verbose=4 --requirements - DevBuild/CrispVoice.app 2>&1
```

Expected on both launches:

```text
Launched stable dev build: .../DevBuild/CrispVoice.app
Signing identity: Apple Development: ...
```

The `codesign` output must not contain `Signature=adhoc` or a `designated => cdhash ...` requirement. After Accessibility is enabled once for the stable app, press `⌃⌥C` after each launch. The CrispVoice capture panel must open both times, and `/tmp/crispvoice-debug.log` must show `PermissionsManager.hasAccessibility trusted=true` rather than opening Accessibility Settings.

- [ ] **Step 12: Run both review stages and address findings**

Stage A checks every requirement in `docs/superpowers/specs/2026-08-06-stable-development-launch-design.md`, including failure-before-kill behavior, rollback, exact process path, documentation, and Xcode Run being out of scope. Stage B reviews Bash correctness, quoting, symlink safety, cleanup traps, process scoping, identity parsing, secret handling, and focused changes. Re-run Steps 8, 10, and 11 after any correction.

- [ ] **Step 13: Commit the verified implementation**

```bash
git add AGENTS.md README.md scripts/run-dev.sh scripts/dev-launch-lib.sh Tests/DevScripts/DevLaunchLibTests.sh Tests/DevScripts/RunDevTests.sh
git commit -m "fix: always launch stable signed development build"
```

