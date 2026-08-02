# Self-Signed Early-Access Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship CrispVoice `v0.2.0` to technical early adopters as a public, self-signed, universal macOS app that installs and upgrades through one verified terminal command.

**Architecture:** A publisher-owned self-signed code-signing identity establishes continuity across builds without satisfying Gatekeeper. Local release tooling builds and verifies one `arm64` + `x86_64` ZIP, while a standalone Bash 3.2 installer downloads the latest public GitHub Release, verifies its checksum and pinned signing certificate, installs it under `~/Applications`, and rolls back failed upgrades.

**Tech Stack:** Bash 3.2, XcodeGen, `xcodebuild`, `codesign`, `security`, `openssl`, `plutil`, `lipo`, `ditto`, `curl`, `shasum`, GitHub Releases, Swift/XCTest.

## Global Constraints

- Preserve the no-backend architecture. Installed-app runtime traffic may go only to `api.anthropic.com` using the user's own key.
- Audio and speech recognition remain on-device; do not add telemetry or content-bearing logs.
- Keep App Sandbox disabled.
- Support macOS 13.0 or later.
- Build one app whose main executable contains exactly `arm64` and `x86_64` slices.
- Install to `~/Applications/CrispVoice.app` without `sudo`, a PKG, a privileged helper, or a background service.
- The release is self-signed and non-notarized. User-facing copy must state that plainly before quarantine is removed.
- Never commit the signing private key, an exported `.p12`, passwords, API keys, or generated `dist/` artifacts.
- Use the exact bundle identifier `com.crispvoice.app`, repository `kirtanework/CrispVoice`, signing common name `CrispVoice Early Access Release`, and first release version `0.2.0`.
- A certificate rotation is a breaking release event; tooling must reject an unexpected certificate fingerprint.
- Do not publish a GitHub Release, push a tag, or change repository visibility without an explicit operator action after the release gate passes.
- Preserve unrelated working-tree changes, including the existing modification to `docs/superpowers/plans/2026-07-05-formalize-tone.md` and the untracked `.dev/` directory.

## File Structure

- `release/CrispVoice-Early-Access-Release.cer` — public DER certificate; contains no private key.
- `release/config.sh` — public release constants and the pinned SHA-1/SHA-256 certificate fingerprints.
- `scripts/check-release-signing.sh` — validates the committed public certificate and, on the publisher Mac, the matching private identity.
- `scripts/release-lib.sh` — focused Bash 3.2 validation helpers used by publisher-side scripts.
- `scripts/verify-release-app.sh` — verifies one extracted `.app` against release metadata and signing policy.
- `scripts/build-release.sh` — tests, builds, signs, packages, and re-verifies the universal artifact.
- `scripts/install.sh` — standalone public installer and upgrader; it must not source repository files.
- `scripts/publish-release.sh` — validates artifacts and performs an explicitly confirmed `gh release create`.
- `Tests/ReleaseScripts/SigningConfigTests.sh` — public certificate/config consistency tests.
- `Tests/ReleaseScripts/ReleaseLibTests.sh` — unit tests for pure release validation helpers.
- `Tests/ReleaseScripts/InstallerTests.sh` — local-file integration tests for install, rejection, and rollback.
- `docs/early-access-installation.md` — user installation, upgrade, permission, and uninstall guide.
- `docs/early-access-release.md` — publisher certificate, build, verification, backup, rotation, and publication runbook.
- `docs/releases/v0.2.0.md` — exact public release notes passed to `gh release create`.

---

### Task 1: Bootstrap the Persistent Signing Identity and Release Metadata

**Files:**
- Create: `release/CrispVoice-Early-Access-Release.cer`
- Create: `release/config.sh`
- Create: `scripts/check-release-signing.sh`
- Create: `Tests/ReleaseScripts/SigningConfigTests.sh`
- Modify: `.gitignore`
- Modify: `project.yml`
- Modify: `Sources/CrispVoice/App/Info.plist`

**Interfaces:**
- Consumes: a manually created Keychain identity with common name `CrispVoice Early Access Release`.
- Produces: `CRISPVOICE_REPOSITORY`, `CRISPVOICE_APP_NAME`, `CRISPVOICE_BUNDLE_ID`, `CRISPVOICE_MIN_MACOS`, `CRISPVOICE_SIGNING_IDENTITY`, `CRISPVOICE_SIGNING_IDENTITY_SHA1`, and `CRISPVOICE_SIGNING_CERT_SHA256` in `release/config.sh`; subsequent tasks source these exact names.

- [ ] **Step 1: Create the signing identity in Keychain Access**

Open Keychain Access, then choose **Keychain Access → Certificate Assistant → Create a Certificate**. Use these exact values:

```text
Name: CrispVoice Early Access Release
Identity Type: Self Signed Root
Certificate Type: Code Signing
Let me override defaults: enabled
Serial Number: 2026080201
Validity Period: 3650 days
Keychain: login
```

Accept the remaining defaults. Confirm the certificate appears under **My Certificates** with an attached private key. This step is performed by the repository owner; the subagent must pause rather than inventing or exporting a private key.

- [ ] **Step 2: Export only the public certificate**

Run:

```bash
mkdir -p release
security find-certificate \
  -c "CrispVoice Early Access Release" \
  -p \
  | openssl x509 -outform DER \
  -out release/CrispVoice-Early-Access-Release.cer
```

Expected: `release/CrispVoice-Early-Access-Release.cer` exists and `security find-identity -v -p codesigning` lists exactly one matching identity.

- [ ] **Step 3: Write the failing signing-config test**

Create `Tests/ReleaseScripts/SigningConfigTests.sh` with this behavior:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT_DIR/release/config.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ "$CRISPVOICE_REPOSITORY" == "kirtanework/CrispVoice" ]] || fail "repository"
[[ "$CRISPVOICE_APP_NAME" == "CrispVoice" ]] || fail "app name"
[[ "$CRISPVOICE_BUNDLE_ID" == "com.crispvoice.app" ]] || fail "bundle id"
[[ "$CRISPVOICE_MIN_MACOS" == "13.0" ]] || fail "minimum macOS"
[[ "$CRISPVOICE_SIGNING_IDENTITY" == "CrispVoice Early Access Release" ]] || fail "identity name"
[[ "$CRISPVOICE_SIGNING_IDENTITY_SHA1" =~ ^[0-9A-F]{40}$ ]] || fail "SHA-1 format"
[[ "$CRISPVOICE_SIGNING_CERT_SHA256" =~ ^[0-9A-F]{64}$ ]] || fail "SHA-256 format"

actual_sha256="$(shasum -a 256 "$ROOT_DIR/release/CrispVoice-Early-Access-Release.cer" | awk '{print toupper($1)}')"
[[ "$actual_sha256" == "$CRISPVOICE_SIGNING_CERT_SHA256" ]] || fail "public certificate fingerprint"

echo "SigningConfigTests: PASS"
```

- [ ] **Step 4: Run the test and confirm the intended failure**

Run:

```bash
/bin/bash Tests/ReleaseScripts/SigningConfigTests.sh
```

Expected: FAIL because `release/config.sh` does not exist.

- [ ] **Step 5: Create the public release configuration derived from the committed certificate**

Create `release/config.sh`. It treats the committed public certificate as the repository's pinned identity and derives its fingerprints deterministically:

```bash
#!/usr/bin/env bash

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
```

Prepend this path initialization before the constants:

```bash
_RELEASE_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```

The installer remains standalone: Task 3 copies the exact evaluated fingerprint strings from this configuration into `scripts/install.sh` and tests that they match.

- [ ] **Step 6: Implement signing-identity validation**

Create `scripts/check-release-signing.sh` so it:

```bash
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
```

- [ ] **Step 7: Make release metadata overridable at build time**

In `Sources/CrispVoice/App/Info.plist`, replace the literal version values with:

```xml
<key>CFBundleShortVersionString</key>
<string>$(MARKETING_VERSION)</string>
<key>CFBundleVersion</key>
<string>$(CURRENT_PROJECT_VERSION)</string>
```

In `project.yml`, add this base setting alongside `MARKETING_VERSION`:

```yaml
CURRENT_PROJECT_VERSION: 1
```

- [ ] **Step 8: Harden secret and artifact exclusions**

Add these exact entries to `.gitignore`:

```gitignore
*.p12
dist/
```

- [ ] **Step 9: Run task-specific and full verification**

Run:

```bash
/bin/bash Tests/ReleaseScripts/SigningConfigTests.sh
./scripts/check-release-signing.sh --require-private-key
xcodegen generate
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -configuration Debug build
```

Expected: both shell checks pass, all XCTest cases pass, and the build ends with `** BUILD SUCCEEDED **`.

- [ ] **Step 10: Commit**

```bash
git add .gitignore project.yml Sources/CrispVoice/App/Info.plist release scripts/check-release-signing.sh Tests/ReleaseScripts/SigningConfigTests.sh
git commit -m "build: add early-access signing configuration"
```

---

### Task 2: Build, Sign, and Verify the Universal Release Artifact

**Files:**
- Create: `scripts/release-lib.sh`
- Create: `scripts/verify-release-app.sh`
- Create: `scripts/build-release.sh`
- Create: `Tests/ReleaseScripts/ReleaseLibTests.sh`

**Interfaces:**
- Consumes: every constant from `release/config.sh` and the matching private identity validated by `scripts/check-release-signing.sh --require-private-key`.
- Produces: `./scripts/build-release.sh [--development] VERSION`; `./scripts/verify-release-app.sh APP_PATH VERSION`; `dist/CrispVoice-VERSION-macos-universal.zip`; and the adjacent `.sha256` file.

- [ ] **Step 1: Write failing tests for pure release validation**

Create `Tests/ReleaseScripts/ReleaseLibTests.sh` that sources `scripts/release-lib.sh` and asserts:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT_DIR/scripts/release-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_success() { "$@" >/dev/null 2>&1 || fail "expected success: $*"; }
expect_failure() { if "$@" >/dev/null 2>&1; then fail "expected failure: $*"; fi; }

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

echo "ReleaseLibTests: PASS"
```

- [ ] **Step 2: Run the tests and confirm the intended failure**

Run:

```bash
/bin/bash Tests/ReleaseScripts/ReleaseLibTests.sh
```

Expected: FAIL because `scripts/release-lib.sh` does not exist.

- [ ] **Step 3: Implement the focused release helper library**

Create `scripts/release-lib.sh` with Bash 3.2-compatible functions:

```bash
#!/usr/bin/env bash

cv_die() {
  echo "Error: $*" >&2
  return 1
}

cv_validate_version() {
  [[ "${1:-}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

cv_require_universal_arches() {
  case " $1 " in
    " arm64 x86_64 "|" x86_64 arm64 ") return 0 ;;
    *) return 1 ;;
  esac
}

cv_uppercase() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

cv_plist_string() {
  /usr/bin/plutil -extract "$1" raw -o - "$2"
}

cv_certificate_sha256() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print toupper($1)}'
}
```

- [ ] **Step 4: Run the release-library tests**

Run:

```bash
/bin/bash Tests/ReleaseScripts/ReleaseLibTests.sh
```

Expected: `ReleaseLibTests: PASS`.

- [ ] **Step 5: Implement extracted-app verification**

Create `scripts/verify-release-app.sh APP_PATH VERSION`. It must:

1. Source `release/config.sh` and `scripts/release-lib.sh`.
2. Validate `VERSION` with `cv_validate_version`.
3. Read `CFBundleIdentifier`, `CFBundleShortVersionString`, `CFBundleExecutable`, and `LSMinimumSystemVersion` from `Contents/Info.plist`.
4. Require bundle ID `com.crispvoice.app`, exact requested version, and minimum macOS `13.0`.
5. Require the executable's `lipo -archs` output to pass `cv_require_universal_arches`.
6. Run `/usr/bin/codesign --verify --deep --strict --verbose=2`.
7. Extract certificate zero with `/usr/bin/codesign --display --extract-certificates "$temp_prefix"`.
8. Compare its SHA-256 with `CRISPVOICE_SIGNING_CERT_SHA256`.
9. Run `/usr/bin/codesign --verify --deep --strict -R="=certificate leaf = H\"$CRISPVOICE_SIGNING_IDENTITY_SHA1\" and identifier \"$CRISPVOICE_BUNDLE_ID\""`.
10. Remove its private temporary directory with a trap and print a success summary containing no secrets.

- [ ] **Step 6: Implement universal build, explicit signing, packaging, and package re-verification**

Create `scripts/build-release.sh [--development] VERSION` with this command flow:

```bash
xcodegen generate
xcodebuild \
  -project CrispVoice.xcodeproj \
  -scheme CrispVoice \
  -destination 'platform=macOS' \
  test

xcodebuild \
  -project CrispVoice.xcodeproj \
  -scheme CrispVoice \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  build
```

Production mode must reject a dirty worktree, require tag `v$VERSION`, and require that tag to resolve to `HEAD`. `--development` may skip only those source-state checks so the release pipeline can be tested before publication.

Sign any nested bundles and Mach-O code discovered under `Contents/Frameworks`, `Contents/PlugIns`, `Contents/XPCServices`, and `Contents/Helpers` from the deepest path outward. Build the candidate list without following symlinks, sort it by descending path length, and sign each existing item with the same identity, runtime, and `--timestamp=none`. The current app has no nested dynamic code, so an empty candidate list is valid. Sign the outer app last with:

```bash
/usr/bin/codesign \
  --force \
  --sign "$CRISPVOICE_SIGNING_IDENTITY_SHA1" \
  --options runtime \
  --timestamp=none \
  --requirements "=designated => certificate leaf = H\"$CRISPVOICE_SIGNING_IDENTITY_SHA1\" and identifier \"$CRISPVOICE_BUNDLE_ID\"" \
  "$APP_PATH"
```

Do not use `--deep` while signing. Then call `scripts/verify-release-app.sh`, package with:

```bash
ditto -c -k --keepParent "$APP_PATH" "$ARCHIVE_PATH"
```

Generate the checksum from inside `dist/` so its recorded filename is only the archive basename:

```bash
(
  cd "$DIST_DIR"
  shasum -a 256 "$(basename "$ARCHIVE_PATH")" > "$(basename "$ARCHIVE_PATH").sha256"
)
```

Finally extract that ZIP into a new temporary directory and call `scripts/verify-release-app.sh` on the extracted app.

- [ ] **Step 7: Run syntax, unit, and development release verification**

Run:

```bash
/bin/bash -n scripts/release-lib.sh scripts/verify-release-app.sh scripts/build-release.sh
/bin/bash Tests/ReleaseScripts/SigningConfigTests.sh
/bin/bash Tests/ReleaseScripts/ReleaseLibTests.sh
./scripts/build-release.sh --development 0.2.0
```

Expected:

```text
SigningConfigTests: PASS
ReleaseLibTests: PASS
** TEST SUCCEEDED **
** BUILD SUCCEEDED **
Release app verification passed for CrispVoice 0.2.0.
```

Also run:

```bash
inspection_dir="$(mktemp -d -t crispvoice-release-inspection)"
ditto -x -k dist/CrispVoice-0.2.0-macos-universal.zip "$inspection_dir"
lipo -archs "$inspection_dir/CrispVoice.app/Contents/MacOS/CrispVoice"
```

Expected: exactly `arm64 x86_64` or `x86_64 arm64`. Remove only the explicitly named inspection directory after recording the result.

- [ ] **Step 8: Run the repository's full task verification**

Run:

```bash
xcodegen generate
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -configuration Debug build
```

Expected: all tests pass and `** BUILD SUCCEEDED **`.

- [ ] **Step 9: Commit**

```bash
git add scripts/release-lib.sh scripts/verify-release-app.sh scripts/build-release.sh Tests/ReleaseScripts/ReleaseLibTests.sh
git commit -m "build: package universal self-signed releases"
```

---

### Task 3: Add the Verified Installer, Upgrade, and Rollback Flow

**Files:**
- Create: `scripts/install.sh`
- Create: `Tests/ReleaseScripts/InstallerTests.sh`

**Interfaces:**
- Consumes: GitHub Release assets named `CrispVoice-VERSION-macos-universal.zip` and `CrispVoice-VERSION-macos-universal.zip.sha256`, signed with the fingerprint in `release/config.sh`.
- Produces: `/bin/bash scripts/install.sh`; default destination `~/Applications/CrispVoice.app`; test-only environment switches `CRISPVOICE_INSTALLER_TEST_MODE`, `CRISPVOICE_VERSION_OVERRIDE`, `CRISPVOICE_RELEASE_BASE_URL`, `CRISPVOICE_INSTALL_ROOT`, `CRISPVOICE_ASSUME_YES`, and `CRISPVOICE_TEST_LAUNCH_FAILURE`.

- [ ] **Step 1: Write a failing local-file installer integration test**

Create `Tests/ReleaseScripts/InstallerTests.sh` to:

1. Require `dist/CrispVoice-0.2.0-macos-universal.zip` and its checksum from Task 2.
2. Source `release/config.sh` and assert `scripts/install.sh` embeds its exact SHA-1 and SHA-256 certificate fingerprint strings.
3. Copy the artifacts into a temporary `releases/download/v0.2.0/` directory.
4. Set a temporary installation root.
5. Run `scripts/install.sh` with test mode, version override `0.2.0`, a `file://` release base URL, confirmation bypass, and launch suppression.
6. Assert that `Applications/CrispVoice.app` exists and passes `scripts/verify-release-app.sh`.
7. Replace the archive with corrupted bytes, rerun the installer, require a nonzero exit, and assert the installed app's executable checksum did not change.
8. Restore the valid archive, set `CRISPVOICE_TEST_LAUNCH_FAILURE=1`, rerun, require a nonzero exit, and assert the previous app was restored.
9. Clean only its `mktemp -d` directory through a trap.

The command under test is:

```bash
CRISPVOICE_INSTALLER_TEST_MODE=1 \
CRISPVOICE_VERSION_OVERRIDE=0.2.0 \
CRISPVOICE_RELEASE_BASE_URL="file://$fixture_root/releases/download" \
CRISPVOICE_INSTALL_ROOT="$test_root" \
CRISPVOICE_ASSUME_YES=1 \
/bin/bash scripts/install.sh
```

- [ ] **Step 2: Run the integration test and confirm the intended failure**

Run:

```bash
/bin/bash Tests/ReleaseScripts/InstallerTests.sh
```

Expected: FAIL because `scripts/install.sh` does not exist.

- [ ] **Step 3: Implement the standalone installer preflight and warning**

Create `scripts/install.sh` with `#!/usr/bin/env bash` and `set -euo pipefail`. It must embed, rather than source, the exact repository, app name, bundle ID, minimum OS, and real SHA-1/SHA-256 certificate fingerprints from `release/config.sh`.

At startup it must:

1. Refuse non-macOS hosts.
2. Parse `sw_vers -productVersion` and require major version 13 or greater.
3. Require `curl`, `ditto`, `shasum`, `plutil`, `lipo`, `codesign`, `xattr`, and `open` at their system paths.
4. Print that the app is self-signed, not notarized by Apple, and will have quarantine removed only from `~/Applications/CrispVoice.app`.
5. Read `y` or `yes` from `/dev/tty`; any other response exits without changing files. `CRISPVOICE_ASSUME_YES=1` is honored only when `CRISPVOICE_INSTALLER_TEST_MODE=1`.

- [ ] **Step 4: Implement release resolution and download verification**

In normal mode:

```bash
effective_url="$(curl -fsSIL -o /dev/null -w '%{url_effective}' -L \
  "https://github.com/$REPOSITORY/releases/latest")"
tag="${effective_url##*/}"
```

Require `tag` to match `vMAJOR.MINOR.PATCH`, set `version="${tag#v}"`, and download the two versioned assets from `https://github.com/$REPOSITORY/releases/download/$tag`.

In test mode only, accept `CRISPVOICE_VERSION_OVERRIDE`, `CRISPVOICE_RELEASE_BASE_URL`, and `CRISPVOICE_INSTALL_ROOT`. Parse the checksum line with `awk`, require its filename to equal the archive basename, calculate the downloaded ZIP's SHA-256 independently, and compare uppercase values before extraction.

- [ ] **Step 5: Implement extracted-app verification without repository dependencies**

Duplicate the security-critical verification inside the standalone installer:

- exact `CrispVoice.app` name;
- exact bundle ID and resolved version;
- exact `LSMinimumSystemVersion` of `13.0`;
- exactly `arm64` and `x86_64` executable architectures;
- strict deep signature verification;
- extracted leaf certificate SHA-256 equals the embedded pinned value; and
- explicit `codesign -R` requirement for the pinned SHA-1 leaf certificate and bundle identifier.

All verification occurs in the private temporary directory before the installed app is touched.

- [ ] **Step 6: Implement atomic install, scoped quarantine removal, launch, and rollback**

Use these paths:

```bash
install_root="${CRISPVOICE_INSTALL_ROOT:-$HOME}"
applications_dir="$install_root/Applications"
destination="$applications_dir/CrispVoice.app"
backup="$temp_dir/Previous-CrispVoice.app"
```

In normal mode, stop a running CrispVoice process with `/usr/bin/killall CrispVoice` and tolerate only the not-running case. Skip process termination in installer test mode so tests cannot disturb the developer's running app. Move an existing destination to `backup`, move the verified staged app to `destination`, and run:

```bash
/usr/bin/xattr -dr com.apple.quarantine "$destination" 2>/dev/null || true
/usr/bin/open "$destination"
```

In test mode, skip `open` unless testing the injected launch failure. Maintain an `installed=0` flag in the exit trap. Until launch succeeds and `installed=1` is set, the trap removes a partial destination and restores `backup`. After success, remove the backup and print the installed version plus permission/API-key next steps.

- [ ] **Step 7: Run installer tests and syntax checks**

Run:

```bash
/bin/bash -n scripts/install.sh Tests/ReleaseScripts/InstallerTests.sh
/bin/bash Tests/ReleaseScripts/InstallerTests.sh
```

Expected: valid install passes, corrupted checksum is rejected without changing the installed app, and injected launch failure restores the previous app.

- [ ] **Step 8: Run the full repository verification**

Run:

```bash
xcodegen generate
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -configuration Debug build
```

Expected: all tests pass and `** BUILD SUCCEEDED **`.

- [ ] **Step 9: Commit**

```bash
git add scripts/install.sh Tests/ReleaseScripts/InstallerTests.sh
git commit -m "feat: add verified early-access installer"
```

---

### Task 4: Document and Guard the Early-Access Release Process

**Files:**
- Create: `scripts/publish-release.sh`
- Create: `docs/early-access-installation.md`
- Create: `docs/early-access-release.md`
- Create: `docs/releases/v0.2.0.md`
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-06-12-crispvoice-design.md`

**Interfaces:**
- Consumes: verified artifacts from Task 2 and the public installer from Task 3.
- Produces: `./scripts/publish-release.sh [--dry-run|--confirm] VERSION RELEASE_NOTES`; `docs/releases/v0.2.0.md`; public user command `curl -fsSL https://raw.githubusercontent.com/kirtanework/CrispVoice/main/scripts/install.sh | /bin/bash`.

- [ ] **Step 1: Write the publisher helper in dry-run-first form**

Create `scripts/publish-release.sh` so it:

1. Sources `release/config.sh` and `scripts/release-lib.sh`.
2. Accepts exactly `--dry-run VERSION RELEASE_NOTES` or `--confirm VERSION RELEASE_NOTES`.
3. Validates the version, notes file, archive, checksum, and packaged app verification in both modes. With `--confirm`, it additionally requires a clean worktree, tag `vVERSION` at `HEAD`, and public repository visibility via `gh repo view --json visibility --jq .visibility`.
4. Prints the exact `gh release create` command in dry-run mode without mutating GitHub.
5. Runs this command only with `--confirm`:

```bash
gh release create "v$VERSION" \
  "dist/CrispVoice-$VERSION-macos-universal.zip" \
  "dist/CrispVoice-$VERSION-macos-universal.zip.sha256" \
  --repo "$CRISPVOICE_REPOSITORY" \
  --title "CrispVoice $VERSION — Self-Signed Early Access" \
  --notes-file "$RELEASE_NOTES"
```

It must never change repository visibility, create a tag, push commits, or export the signing private key.

- [ ] **Step 2: Write the early-adopter installation guide**

Create `docs/early-access-installation.md` with:

- the self-signed/non-notarized warning;
- the one-command install and upgrade command;
- a safer three-step `curl -o`, inspect, then `/bin/bash` alternative;
- a plain-language list of downloaded and changed files;
- first-launch Microphone, Speech Recognition, Accessibility, and Anthropic-key setup;
- managed-Mac and **Open Anyway** troubleshooting;
- uninstall by moving only `~/Applications/CrispVoice.app` to Trash; and
- optional Keychain cleanup identified as a separate, explicit destructive action.

- [ ] **Step 3: Write the publisher runbook**

Create `docs/early-access-release.md` with the exact Keychain Access values from Task 1, public-certificate fingerprint checks, encrypted offline `.p12` backup instructions, `v0.2.0` build and verification commands, GitHub publication dry run, explicit publish command, certificate-loss/rotation consequences, Intel test requirement, TCC continuity test, and privacy smoke test.

State that the private-key backup password must not be placed in shell history, the repository, `.env`, release notes, or GitHub Secrets.

- [ ] **Step 4: Write the concrete `v0.2.0` public release notes**

Create `docs/releases/v0.2.0.md` with these sections and facts:

```markdown
# CrispVoice 0.2.0 — Self-Signed Early Access

This is a technical early-access release for macOS 13 or later. The app is self-signed and is not notarized by Apple.

## Install or upgrade

Run the verified installer documented in the repository's early-access installation guide.

## Included

- One universal app containing Apple Silicon (`arm64`) and Intel (`x86_64`) code.
- On-device Apple Speech transcription.
- Direct Anthropic API requests using the user's own Keychain-stored key.
- No developer backend or telemetry.

## Verification

The release contains a SHA-256 checksum. The installer also verifies the bundle identifier, both architectures, code integrity, and the pinned CrispVoice self-signed certificate before installation.
```

- [ ] **Step 5: Update README installation and project status**

Replace the signed/notarized promise with the early-access command:

```bash
curl -fsSL https://raw.githubusercontent.com/kirtanework/CrispVoice/main/scripts/install.sh | /bin/bash
```

Link to both new guides. State that the installer verifies the GitHub artifact and pinned self-signed identity, removes quarantine from only the installed app, and does not make the app Apple-notarized.

- [ ] **Step 6: Amend the original distribution roadmap**

In `docs/superpowers/specs/2026-06-12-crispvoice-design.md`, split Phase 4 into:

```text
Phase 4a — Self-signed early access: public GitHub Release, universal app, verified terminal installer, explicit Gatekeeper bypass, and technical early adopters.
Phase 4b — Developer ID public release: Apple Developer Program, Developer ID signing, notarization, and a clean Gatekeeper path for broader distribution.
```

Keep the no-backend, BYOK, privacy, and no-App-Sandbox invariants unchanged.

- [ ] **Step 7: Run documentation, shell, and full verification**

Run:

```bash
/bin/bash -n scripts/*.sh Tests/ReleaseScripts/*.sh
rg -n "signed and notarized|Developer ID|self-signed|notarized" README.md docs/early-access-installation.md docs/early-access-release.md docs/superpowers/specs/2026-06-12-crispvoice-design.md
xcodegen generate
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -configuration Debug build
```

Expected: all shell syntax checks pass; copy consistently distinguishes self-signed early access from notarized distribution; all tests pass; and the build succeeds. The publication dry run occurs at the final gate after the production tag exists.

- [ ] **Step 8: Commit**

```bash
git add scripts/publish-release.sh docs/early-access-installation.md docs/early-access-release.md docs/releases/v0.2.0.md README.md docs/superpowers/specs/2026-06-12-crispvoice-design.md
git commit -m "docs: add self-signed early-access distribution"
```

---

## Final Early-Access Release Gate

Do not publish or claim early-access readiness until every item below has real observed evidence.

- [ ] Export the `CrispVoice Early Access Release` identity from Keychain Access as an encrypted `.p12`, store it in an offline backup location outside the repository, and confirm `git status --short` does not list the backup or its password.

- [ ] Run all release-script tests:

```bash
/bin/bash Tests/ReleaseScripts/SigningConfigTests.sh
/bin/bash Tests/ReleaseScripts/ReleaseLibTests.sh
/bin/bash Tests/ReleaseScripts/InstallerTests.sh
```

- [ ] Run the complete XCTest suite and clean Debug build:

```bash
xcodegen generate
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -configuration Debug clean build
```

- [ ] Build and inspect the release candidate:

```bash
./scripts/build-release.sh --development 0.2.0
release_gate_dir="$(mktemp -d -t crispvoice-v0.2.0-gate)"
ditto -x -k dist/CrispVoice-0.2.0-macos-universal.zip "$release_gate_dir"
./scripts/verify-release-app.sh "$release_gate_dir/CrispVoice.app" 0.2.0
```

- [ ] Confirm Gatekeeper does not mistake the self-signed build for a notarized app:

```bash
if spctl --assess --verbose=4 --type execute "$release_gate_dir/CrispVoice.app"; then
  echo "Unexpected: self-signed app passed Gatekeeper assessment." >&2
  exit 1
else
  echo "Expected: Gatekeeper rejected the non-notarized app."
fi
```

- [ ] Launch the Intel slice under Rosetta on Apple Silicon and confirm the menu-bar process remains running long enough to initialize:

```bash
arch -x86_64 "$release_gate_dir/CrispVoice.app/Contents/MacOS/CrispVoice" &
rosetta_pid=$!
sleep 3
kill -0 "$rosetta_pid"
kill "$rosetta_pid"
wait "$rosetta_pid" || true
```

- [ ] Obtain an installation, launch, permission, dictation, rewrite, and paste smoke test from an actual Intel Mac. Until observed, describe the artifact as containing Intel support but do not claim verified Intel compatibility.

- [ ] Install two differently versioned builds signed by the same self-signed certificate. Grant Microphone, Speech Recognition, and Accessibility to the first build, upgrade with the installer, and record whether macOS preserves each grant. If any grant repeats, document that behavior in `docs/early-access-installation.md`.

- [ ] Corrupt a release ZIP and confirm the installer rejects it without changing the working app.

- [ ] Sign a test build with a different identity and confirm both `verify-release-app.sh` and `install.sh` reject it.

- [ ] Run one complete dictate → on-device transcript → Anthropic rewrite → paste flow while observing network connections. Confirm installed-app content traffic goes only to `api.anthropic.com`; separately confirm GitHub traffic occurs only during install or upgrade.

- [ ] Confirm `git status --short`, `git ls-files`, and the GitHub Release assets contain no `.p12`, private key, password, API key, audio, transcript, message text, or `dist/` artifact committed to source control.

- [ ] After explicit operator approval, create tag `v0.2.0`, rebuild in production mode, run `./scripts/publish-release.sh --dry-run 0.2.0 docs/releases/v0.2.0.md`, inspect its output, and only then rerun with `--confirm`.
