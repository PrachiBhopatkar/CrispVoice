# CrispVoice Stable Development Launch Design

**Date:** 2026-08-06
**Status:** Approved for implementation planning

## 1. Context

CrispVoice requires macOS Accessibility permission to synthesize paste keystrokes. macOS associates that permission with the application's code identity. An ad-hoc-signed development build has a designated requirement tied to its exact code hash, so rebuilding the app changes its identity and invalidates the prior Accessibility grant.

Commit `9671b76` introduced `scripts/run-dev.sh` to avoid this problem by copying the build to `DevBuild/CrispVoice.app` and signing it with a persistent Apple Development identity. The regression resurfaced because repository instructions still launched an ad-hoc build directly from Xcode DerivedData. The current launcher also falls back to that same unsafe ad-hoc identity when it cannot find an Apple Development identity.

The supported development workflow must make the stable copy the only app launched by terminal commands and coding agents. Direct use of Xcode's Run button is out of scope for this change.

## 2. Goals

- Make `./scripts/run-dev.sh` the single supported development launch command.
- Build from a deterministic repository-local DerivedData directory.
- Sign every launched development build with one valid Apple Development identity.
- Prove the staged app has a stable, non-ad-hoc identity before stopping the running app.
- Always launch `DevBuild/CrispVoice.app`, never a DerivedData copy.
- Verify the process that starts is executing the stable copy.
- Preserve the last working stable development build when build, signing, replacement, or launch verification fails.
- Remove contradictory repository instructions that launch a DerivedData app.

## 3. Non-goals

- Supporting or changing Xcode's Run button.
- Changing CrispVoice runtime features, permissions, bundle identifier, or production behavior.
- Automating approval of Accessibility, Microphone, or Speech Recognition permissions.
- Resetting TCC or modifying macOS privacy databases.
- Changing the early-access distribution signing design in this task.
- Committing a private key, certificate password, signing fingerprint, or machine-specific Xcode path.

## 4. Decision

Harden the existing `scripts/run-dev.sh` workflow and make it fail closed. The launcher must never open an ad-hoc-signed app. It must identify exactly one valid Apple Development identity, build into a known local directory, stage and sign a stable app copy, verify that identity, and only then replace and launch the stable application.

This approach is preferred over putting the owner's signing identity in `project.yml`, which would make public clones and CI depend on a private local identity. It is also preferred over adding a runtime warning inside CrispVoice, which would detect the wrong app only after the unsafe launch had already occurred.

## 5. Canonical paths and identity

The launcher uses these repository-relative, gitignored paths:

- Build products: `.build/DerivedData`
- Installed development app: `DevBuild/CrispVoice.app`
- Temporary staged app and rollback backup: private entries under `DevBuild/` removed when the command exits

The launcher queries the login Keychain for valid code-signing identities whose names start with `Apple Development:`. Exactly one match is required. No match or multiple matches is an error with actionable output. The selected identity's SHA-1 fingerprint and display name remain in process memory and command output only; they are not written into tracked files.

The existing `CrispVoice Early Access Release` identity is not used for development builds. Keeping development and release identities separate prevents local development from implicitly sharing production authorization state.

## 6. Launch flow

`./scripts/run-dev.sh` performs these steps in order:

1. Resolve the repository root and confirm required macOS tools are available.
2. Resolve exactly one valid Apple Development identity before starting a build.
3. Generate the Xcode project with XcodeGen.
4. Build CrispVoice in Debug configuration with an explicit repository-local `-derivedDataPath`.
5. Resolve the one expected build product at `.build/DerivedData/Build/Products/Debug/CrispVoice.app`; do not search global DerivedData or use `head -1`.
6. Copy that product to a fresh staging location under `DevBuild/`.
7. Sign the staged code hierarchy with the selected Apple Development identity.
8. Verify the staged bundle before changing the running app or stable copy.
9. Stop all currently running processes named CrispVoice.
10. Move the previous stable app to a temporary rollback backup, then move the verified staged app to `DevBuild/CrispVoice.app`.
11. Launch the stable app.
12. Wait for CrispVoice to start, resolve its executable path, and require it to equal `DevBuild/CrispVoice.app/Contents/MacOS/CrispVoice` after physical-path normalization.
13. Delete the rollback backup only after launch verification succeeds.
14. Print the verified app path and signing identity.

The script remains non-interactive during normal success. It may allow focused test-only overrides, but those overrides must be rejected unless an explicit test-mode switch is enabled.

## 7. Verification policy

Before installation into `DevBuild/`, the staged app must satisfy all of the following:

- It is a real directory rather than a symbolic link.
- `Contents/Info.plist` is present and reports bundle identifier `com.crispvoice.app`.
- The expected main executable exists and is not a symbolic link.
- `codesign --verify --deep --strict` succeeds.
- The signature is not ad-hoc.
- The embedded leaf certificate fingerprint matches the Apple Development identity selected before the build.
- The designated requirement is present and does not contain a `cdhash` identity.
- The signing information contains a non-empty Team Identifier.

These checks verify the property that matters for TCC continuity: successive development builds are recognized by a certificate-backed designated requirement rather than by an exact build hash.

## 8. Failure handling and rollback

- Missing tools, identity ambiguity, build failure, signing failure, or staged-app verification failure exits before the current CrispVoice process or stable app is touched.
- The previous stable app remains available until the replacement has been fully verified.
- Replacement or launch-verification failure restores the previous stable app when one existed.
- A failed first launch removes the incomplete new stable copy.
- Temporary staging and backup entries are removed on successful completion and safely handled on failure.
- The launcher never resets privacy permissions, changes trust settings, or silently falls back to ad-hoc signing.
- Errors identify the failed stage and give the next corrective action without printing secrets.

## 9. Documentation changes

Update `AGENTS.md` so its run instructions invoke only:

```bash
./scripts/run-dev.sh
```

Remove the command that searches `~/Library/Developer/Xcode/DerivedData` and opens the first result. Keep the README aligned with the same supported command and state that direct Xcode Run is not covered by the stable-permission workflow.

Historical implementation plans remain historical records and do not need mechanical rewrites, provided all current operational instructions point to the canonical launcher.

## 10. Testing and verification

Implementation follows TDD for the launcher's testable logic. Shell tests must cover:

- No Apple Development identity.
- Multiple matching Apple Development identities.
- Deterministic build-product selection.
- Build, copy, signing, and signature-verification failures.
- Rejection of an ad-hoc signature.
- Rejection of a `cdhash`-based designated requirement.
- Rejection of the wrong bundle identifier or certificate fingerprint.
- Preservation of the prior stable app before preflight succeeds.
- Rollback after replacement or launch-verification failure.
- Successful launch only from the normalized `DevBuild/CrispVoice.app` path.
- Rejection of test-only overrides outside explicit test mode.

Before completion:

1. Run the launch-script test suite with the system Bash version.
2. Generate the project and run the full XCTest suite.
3. Run a clean Debug build.
4. Run `./scripts/run-dev.sh` twice.
5. Confirm both launches report `DevBuild/CrispVoice.app`, certificate-backed designated requirements, and the same Apple Development identity.
6. Confirm `AXIsProcessTrusted()` remains true on the second launch after the user grants Accessibility to the stable app once.
7. Confirm the CrispVoice hotkey opens its capture panel rather than Accessibility Settings.

## 11. Relationship to early-access distribution

This fix is a prerequisite for reliable local development but does not by itself select the public release identity. It provides direct evidence that an ad-hoc identity is unsuitable when Accessibility approval must survive code changes. The early-access distribution design must account for that evidence before its implementation resumes.

