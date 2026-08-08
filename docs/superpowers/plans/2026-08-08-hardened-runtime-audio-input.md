# Hardened Runtime Audio Input Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure every Hardened Runtime CrispVoice build embeds the Boolean Audio Input entitlement and reject release artifacts that do not.

**Architecture:** One minimal application entitlement file is the source of truth for Xcode, stable-development signing, and release signing. Shell verification extracts entitlements from the exact signed application and validates the Boolean value before packaging or installation; development signing adopts Hardened Runtime so local testing exercises the release security configuration.

**Tech Stack:** Swift/XcodeGen project configuration, macOS `codesign`, `plutil`, Bash 3.2-compatible release and installer scripts, shell integration tests, XCTest.

## Global Constraints

- App Sandbox remains disabled.
- `com.apple.security.device.audio-input = true` is the only new application entitlement.
- Both stable development and public release outer-app signatures use Hardened Runtime and the same Audio Input entitlement file.
- Nested code keeps the existing signing policy and does not receive application-only entitlements.
- Release and installer verification inspect the entitlement embedded in the signed artifact, not only the source file.
- Installer rejection occurs before replacing `~/Applications/CrispVoice.app`.
- Audio and transcripts remain on device; runtime network traffic remains limited to `api.anthropic.com` with the user's own key.
- No telemetry, content-bearing logs, secrets, private keys, model binaries, release archives, tags, pushes, or GitHub Releases are added by this plan.
- Preserve bundle identifier `com.crispvoice.app`, minimum macOS `13.0`, existing stable signing identities, and the non-sandboxed architecture.
- Every task runs `xcodegen generate`, the complete XCTest suite, and a clean Debug build before commit.

---

## File Map

- `Sources/CrispVoice/App/CrispVoice.entitlements` — owns the minimal application entitlement dictionary.
- `project.yml` — points the application target at the entitlement file.
- `scripts/release-lib.sh` — provides a testable release outer-app signing function and, in Task 2, the embedded-entitlement Boolean validator.
- `scripts/build-release.sh` — signs the outer release app through the shared function with Hardened Runtime and explicit entitlements.
- `scripts/dev-launch-lib.sh` — validates stable development signing, Hardened Runtime, and embedded Audio Input entitlement.
- `scripts/run-dev.sh` — signs the stable development app with Hardened Runtime and explicit entitlements.
- `scripts/verify-release-app.sh` — extracts and validates embedded release entitlements.
- `scripts/install.sh` — independently extracts and validates embedded entitlements before installation.
- `Tests/ReleaseScripts/ReleaseLibTests.sh` — covers release signing arguments and entitlement Boolean parsing.
- `Tests/ReleaseScripts/BuildReleaseTests.sh` — covers early rejection when the source entitlement file is unavailable.
- `Tests/ReleaseScripts/InstallerTests.sh` — proves a correctly signed but entitlement-free release is rejected without changing the installed app.
- `Tests/DevScripts/DevLaunchLibTests.sh` — covers stable-signature runtime and entitlement validation.
- `Tests/DevScripts/RunDevTests.sh` — exercises the complete development launcher with the hardened signing contract.

---

### Task 1: Embed Audio Input in Release and Stable Development Signatures

**Files:**
- Create: `Sources/CrispVoice/App/CrispVoice.entitlements`
- Modify: `project.yml`
- Modify: `scripts/release-lib.sh`
- Modify: `scripts/build-release.sh`
- Modify: `scripts/dev-launch-lib.sh`
- Modify: `scripts/run-dev.sh`
- Modify: `Tests/ReleaseScripts/ReleaseLibTests.sh`
- Modify: `Tests/ReleaseScripts/BuildReleaseTests.sh`
- Modify: `Tests/DevScripts/DevLaunchLibTests.sh`
- Modify: `Tests/DevScripts/RunDevTests.sh`

**Interfaces:**
- Consumes: existing release identity variables from `release/config.sh`; existing `cv_die`, `cv_dev_die`, and stable-signing verification functions.
- Produces: `Sources/CrispVoice/App/CrispVoice.entitlements`; `cv_sign_release_app CODESIGN_BIN IDENTITY ENTITLEMENTS REQUIREMENT APP_PATH`; expanded `cv_dev_require_signing APP_PATH EXPECTED_SHA1 CODESIGN_BIN SHASUM_BIN PLUTIL_BIN` contract; Hardened Runtime outer signatures with embedded Audio Input entitlement.

- [ ] **Step 1: Add failing release signing and missing-file tests**

In `Tests/ReleaseScripts/ReleaseLibTests.sh`, create a real temporary entitlement plist and a strict fake `codesign` executable. The fake succeeds only for this exact boundary contract and writes a marker:

```bash
expected_entitlements="$TEST_TEMP/CrispVoice.entitlements"
sign_marker="$TEST_TEMP/release-sign-called"
/usr/bin/plutil -create xml1 "$expected_entitlements"
/usr/bin/plutil -insert com.apple.security.device.audio-input -bool true "$expected_entitlements"

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
```

Also assert that a nonexistent or symlinked entitlement path returns failure before the fake signer runs. In `Tests/ReleaseScripts/BuildReleaseTests.sh`, extend `make_release_fixture` to create `Sources/CrispVoice/App`, copy the real entitlement source when present, and add a scenario that removes it and expects `build-release.sh --development 0.2.2` to fail before signing preflight with `Audio Input entitlement file is missing or invalid.`

- [ ] **Step 2: Run release shell tests and confirm RED**

Run:

```bash
bash Tests/ReleaseScripts/ReleaseLibTests.sh
bash Tests/ReleaseScripts/BuildReleaseTests.sh
```

Expected: `ReleaseLibTests.sh` fails because `cv_sign_release_app` is undefined. After the test harness reaches the fixture case, `BuildReleaseTests.sh` fails because the current build script does not validate the entitlement file.

- [ ] **Step 3: Add failing development signing tests**

In `Tests/DevScripts/RunDevTests.sh`, create the fixture entitlement at `Sources/CrispVoice/App/CrispVoice.entitlements` and nested code under a standard macOS nested-code root. Change the fake `codesign` signing branches so success requires the nested candidate to be signed first without application entitlements:

```bash
--force --sign AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA \
--options runtime \
"$nested_candidate"
```

Then require the outer app to be signed last with the entitlement file and without signing-time `--deep`:

```bash
--force --sign AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA \
--options runtime \
--entitlements "$CV_TEST_FIXTURE_ROOT/Sources/CrispVoice/App/CrispVoice.entitlements" \
"$staged_app"
```

Retain `--deep` only for strict verification. Make the fake signature display include `flags=0x10000(runtime)`. Add a display-entitlements branch that writes a Boolean-true plist to the requested output path, and assert a nested-signing failure preserves the prior stable app.

In `Tests/DevScripts/DevLaunchLibTests.sh`, expand the fake signer to support three literal scenarios:

```text
success: signing display contains flags=0x10000(runtime), entitlement plist contains Boolean true
missing_runtime: signing display contains flags=0x0(none), entitlement plist contains Boolean true
missing_audio_input: signing display contains flags=0x10000(runtime), entitlement plist contains an empty dictionary
```

Call the expanded `cv_dev_require_signing` with `/usr/bin/plutil`; require success only for `success`, and require failure messages containing `Hardened Runtime` and `Audio Input entitlement` for the two rejection scenarios.

- [ ] **Step 4: Run development shell tests and confirm RED**

Run:

```bash
bash Tests/DevScripts/DevLaunchLibTests.sh
bash Tests/DevScripts/RunDevTests.sh
```

Expected: failures because `cv_dev_require_signing` has no `PLUTIL_BIN` parameter or runtime/entitlement inspection and `run-dev.sh` still invokes the old signing command.

- [ ] **Step 5: Create the minimal entitlement source and Xcode configuration**

Create `Sources/CrispVoice/App/CrispVoice.entitlements` exactly as:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
```

In `project.yml`, replace the empty setting with:

```yaml
CODE_SIGN_ENTITLEMENTS: Sources/CrispVoice/App/CrispVoice.entitlements
```

- [ ] **Step 6: Implement the release signing boundary**

Add to `scripts/release-lib.sh`:

```bash
cv_sign_release_app() {
  local codesign_bin="$1"
  local identity="$2"
  local entitlements="$3"
  local requirement="$4"
  local app_path="$5"

  [[ -f "$entitlements" && ! -L "$entitlements" ]] || {
    cv_die "Audio Input entitlement file is missing or invalid."
    return 1
  }

  "$codesign_bin" \
    --force \
    --sign "$identity" \
    --options runtime \
    --timestamp=none \
    --entitlements "$entitlements" \
    --requirements "$requirement" \
    "$app_path"
}
```

In `scripts/build-release.sh`, define and validate:

```bash
ENTITLEMENTS_PATH="$ROOT_DIR/Sources/CrispVoice/App/CrispVoice.entitlements"
[[ -f "$ENTITLEMENTS_PATH" && ! -L "$ENTITLEMENTS_PATH" ]] \
  || cv_die "Audio Input entitlement file is missing or invalid."
```

Replace only the outer-app `codesign` call with `cv_sign_release_app`, passing `/usr/bin/codesign`, the pinned identity, `ENTITLEMENTS_PATH`, the existing designated requirement string, and `APP_PATH`. Keep nested-code signing unchanged.

- [ ] **Step 7: Implement the stable development signing boundary**

In `scripts/run-dev.sh`, define:

```bash
ENTITLEMENTS_PATH="$ROOT_DIR/Sources/CrispVoice/App/CrispVoice.entitlements"
```

Validate that it is a regular non-symlink before XcodeGen runs. Sign nested code inside-out using the release builder's standard roots and candidate policy, without app entitlements. Then sign the staged app last with the entitlement file (and without signing-time `--deep`):

```bash
"$CODESIGN_BIN" \
  --force \
  --sign "$selected_sha1" \
  --options runtime \
  --entitlements "$ENTITLEMENTS_PATH" \
  "$staged_app"
```

Expand `cv_dev_require_signing` in `scripts/dev-launch-lib.sh` to accept `plutil_bin` as argument 5. Require the existing signature display to contain `flags=0x10000(runtime)`. Extract XML entitlements into the function's existing private temporary directory:

```bash
"$codesign_bin" --display --entitlements "$temporary_dir/entitlements.plist" --xml "$app_path"
audio_input="$("$plutil_bin" \
  -extract com.apple.security.device.audio-input raw \
  -expect bool -o - "$temporary_dir/entitlements.plist" 2>/dev/null)" \
  || cv_dev_die "Stable development signature is missing the Audio Input entitlement"
[[ "$audio_input" == true ]] \
  || cv_dev_die "Stable development signature is missing the Audio Input entitlement"
```

Integrate extraction into the function's existing `status` flow: record failures, remove the exact private temporary directory, and only then return the entitlement-specific error. No extraction or parsing branch may bypass cleanup. Pass `PLUTIL_BIN` from `run-dev.sh` to the expanded function.

- [ ] **Step 8: Run focused shell tests and confirm GREEN**

Run:

```bash
bash Tests/ReleaseScripts/ReleaseLibTests.sh
bash Tests/ReleaseScripts/BuildReleaseTests.sh
bash Tests/DevScripts/DevLaunchLibTests.sh
bash Tests/DevScripts/RunDevTests.sh
bash -n scripts/release-lib.sh scripts/build-release.sh scripts/dev-launch-lib.sh scripts/run-dev.sh
```

Expected: every command exits 0 and each suite prints its `PASS` line.

- [ ] **Step 9: Run the full task verification**

Run:

```bash
xcodegen generate
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -configuration Debug clean build
```

Expected: all tests pass and the build ends with `** BUILD SUCCEEDED **`.

- [ ] **Step 10: Review and commit Task 1**

Complete both review stages. Verify exact key spelling, Boolean type, no `com.apple.security.app-sandbox`, unchanged nested signing, focused files, and no secrets. After clean review and repeated covering tests:

```bash
git add \
  Sources/CrispVoice/App/CrispVoice.entitlements \
  project.yml \
  scripts/release-lib.sh \
  scripts/build-release.sh \
  scripts/dev-launch-lib.sh \
  scripts/run-dev.sh \
  Tests/ReleaseScripts/ReleaseLibTests.sh \
  Tests/ReleaseScripts/BuildReleaseTests.sh \
  Tests/DevScripts/DevLaunchLibTests.sh \
  Tests/DevScripts/RunDevTests.sh
git commit -m "fix: sign CrispVoice with audio input entitlement"
```

---

### Task 2: Enforce Embedded Audio Input Entitlement Before Release and Installation

**Files:**
- Modify: `scripts/release-lib.sh`
- Modify: `scripts/verify-release-app.sh`
- Modify: `scripts/install.sh`
- Modify: `Tests/ReleaseScripts/ReleaseLibTests.sh`
- Modify: `Tests/ReleaseScripts/InstallerTests.sh`

**Interfaces:**
- Consumes: Task 1's signed application containing `com.apple.security.device.audio-input = true`; existing pinned release identities and archive fixtures.
- Produces: `cv_require_audio_input_entitlement ENTITLEMENTS_PLIST PLUTIL_BIN`; release verifier and standalone installer gates that accept only an embedded Boolean `true` value.

- [ ] **Step 1: Add failing Boolean entitlement parser tests**

In `Tests/ReleaseScripts/ReleaseLibTests.sh`, create four literal plist fixtures with `/usr/bin/plutil`: Boolean true, Boolean false, string `true`, and missing key. Add:

```bash
expect_success cv_require_audio_input_entitlement "$true_plist" /usr/bin/plutil
expect_failure cv_require_audio_input_entitlement "$false_plist" /usr/bin/plutil
expect_failure cv_require_audio_input_entitlement "$string_plist" /usr/bin/plutil
expect_failure cv_require_audio_input_entitlement "$missing_plist" /usr/bin/plutil
```

Each failing case must report `Signed app is missing the required Boolean Audio Input entitlement.`

- [ ] **Step 2: Run parser tests and confirm RED**

Run:

```bash
bash Tests/ReleaseScripts/ReleaseLibTests.sh
```

Expected: FAIL because `cv_require_audio_input_entitlement` is undefined.

- [ ] **Step 3: Add a failing installer preservation test using a valid pinned signature**

In `Tests/ReleaseScripts/InstallerTests.sh`, after the first valid installation, extract a second copy of the known-good archive. Re-sign its outer app with the pinned private identity and Hardened Runtime but deliberately omit `--entitlements`:

```bash
/usr/bin/codesign \
  --force \
  --sign "$CRISPVOICE_SIGNING_IDENTITY_SHA1" \
  --options runtime \
  --timestamp=none \
  --requirements "=designated => certificate leaf = H\"$CRISPVOICE_SIGNING_IDENTITY_SHA1\" and identifier \"$CRISPVOICE_BUNDLE_ID\"" \
  "$missing_entitlement_app"
```

Verify with `codesign --display --entitlements - --xml` that the negative fixture emits no entitlement plist, then package it with `ditto`, write its matching SHA-256 record, and run the installer against that fixture. Assert:

```bash
[[ "$status" -ne 0 ]] || fail "installer accepted a signed app without Audio Input entitlement"
[[ "$output" == *"Signed app is missing the required Boolean Audio Input entitlement."* ]] \
  || fail "installer rejected the fixture for the wrong reason: $output"
[[ "$after_rejection_sha256" == "$original_executable_sha256" ]] \
  || fail "missing-entitlement release changed the installed executable"
```

Also call `scripts/verify-release-app.sh` directly on the re-signed app and require the same entitlement-specific rejection. Restore the original archive/checksum fixture before the existing corruption and rollback scenarios.

- [ ] **Step 4: Run installer tests and confirm RED**

First ensure Task 1 has produced a valid local fixture:

```bash
./scripts/build-release.sh --development 0.2.0
bash Tests/ReleaseScripts/InstallerTests.sh
```

Expected: the release build succeeds, then `InstallerTests.sh` fails because the current verifier and installer accept the correctly signed entitlement-free negative fixture.

- [ ] **Step 5: Implement the shared release Boolean validator**

Add to `scripts/release-lib.sh`:

```bash
cv_require_audio_input_entitlement() {
  local entitlements_plist="$1"
  local plutil_bin="$2"
  local audio_input

  audio_input="$("$plutil_bin" \
    -extract com.apple.security.device.audio-input raw \
    -expect bool -o - "$entitlements_plist" 2>/dev/null)" || {
      cv_die "Signed app is missing the required Boolean Audio Input entitlement."
      return 1
    }
  [[ "$audio_input" == true ]] || {
    cv_die "Signed app is missing the required Boolean Audio Input entitlement."
    return 1
  }
}
```

- [ ] **Step 6: Enforce the embedded entitlement in the release verifier**

In `scripts/verify-release-app.sh`, reuse `certificate_dir` as the private verification directory and define `entitlements_plist="$certificate_dir/entitlements.plist"`. After strict signature verification and before certificate acceptance, extract the signed app's XML entitlements:

```bash
/usr/bin/codesign \
  --display \
  --entitlements "$entitlements_plist" \
  --xml \
  "$APP_PATH" >/dev/null 2>&1 \
  || cv_die "Unable to read signed app entitlements."
cv_require_audio_input_entitlement "$entitlements_plist" /usr/bin/plutil
```

Do not validate the source `CrispVoice.entitlements` file here; this boundary validates the signed artifact.

- [ ] **Step 7: Enforce the embedded entitlement in the standalone installer**

Add a Bash 3.2-compatible `require_audio_input_entitlement` function to `scripts/install.sh` with the same strict `plutil -expect bool` behavior and error text as the shared release helper. Inside `verify_extracted_app`, set `entitlements_plist="$temp_dir/entitlements.plist"`; after strict signature verification and before certificate acceptance, run:

```bash
/usr/bin/codesign \
  --display \
  --entitlements "$entitlements_plist" \
  --xml \
  "$app_path" >/dev/null 2>&1 \
  || die "Unable to read signed app entitlements."
require_audio_input_entitlement "$entitlements_plist"
```

Keep this logic self-contained because the public `curl | /bin/bash` installer cannot source repository-local helpers.

- [ ] **Step 8: Run focused shell tests and confirm GREEN**

Run:

```bash
bash Tests/ReleaseScripts/ReleaseLibTests.sh
bash Tests/ReleaseScripts/BuildReleaseTests.sh
./scripts/build-release.sh --development 0.2.0
bash Tests/ReleaseScripts/InstallerTests.sh
bash Tests/DevScripts/DevLaunchLibTests.sh
bash Tests/DevScripts/RunDevTests.sh
bash -n scripts/release-lib.sh scripts/verify-release-app.sh scripts/build-release.sh scripts/install.sh scripts/dev-launch-lib.sh scripts/run-dev.sh
```

Expected: every command exits 0; shell suites print `PASS`; the development release is accepted; the entitlement-free pinned-signature fixture is rejected with the exact entitlement error without changing the prior installation.

- [ ] **Step 9: Run the full test suite and clean build**

Run:

```bash
xcodegen generate
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -configuration Debug clean build
```

Expected: all tests pass and the build ends with `** BUILD SUCCEEDED **`.

- [ ] **Step 10: Inspect the non-published release artifact**

Run:

```bash
./scripts/build-release.sh --development 0.2.2
inspection_dir="$(mktemp -d -t crispvoice-audio-input-inspection)"
ditto -x -k dist/CrispVoice-0.2.2-macos-universal.zip "$inspection_dir"
codesign -dv --verbose=4 "$inspection_dir/CrispVoice.app" 2>&1
codesign --display --entitlements - --xml "$inspection_dir/CrispVoice.app"
/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$inspection_dir/CrispVoice.app/Contents/Info.plist"
./scripts/verify-release-app.sh "$inspection_dir/CrispVoice.app" 0.2.2
```

Expected: signature output contains `flags=0x10000(runtime)`; entitlements XML contains only Boolean `com.apple.security.device.audio-input = true`; the microphone usage text is present; verification passes. Remove only the exact `inspection_dir` after inspection. Do not tag, push, publish, or install the archive.

- [ ] **Step 11: Verify the stable development copy twice**

Run twice:

```bash
./scripts/run-dev.sh
codesign -dv --verbose=4 DevBuild/CrispVoice.app 2>&1
codesign --display --entitlements - --xml DevBuild/CrispVoice.app
```

Expected on both runs: the launcher reports `DevBuild/CrispVoice.app`; signature output contains `flags=0x10000(runtime)` and the same non-ad-hoc stable identity; entitlements XML contains Boolean Audio Input `true`; the app launches from `DevBuild`, and no privacy database is reset.

- [ ] **Step 12: Review and commit Task 2**

Complete both review stages. Confirm verifier and installer inspect the signed artifact, Boolean type is enforced, rejection precedes installation replacement, the old v0.2.1-shaped artifact is rejected, and no test-only switch weakens production verification. Re-run every covering command after fixes, then:

```bash
git add \
  scripts/release-lib.sh \
  scripts/verify-release-app.sh \
  scripts/install.sh \
  Tests/ReleaseScripts/ReleaseLibTests.sh \
  Tests/ReleaseScripts/InstallerTests.sh
git commit -m "fix: require audio input entitlement in releases"
```

---

## Final Gate

After both tasks are committed, run a whole-branch review from design commit `f797ecf` through `HEAD`. Re-run `git diff --check` and confirm `git status --short` contains only the user's pre-existing `.dev/` entry. Do not create v0.2.2, push commits, publish a GitHub Release, reset TCC, or install the development archive on the tester Mac.
