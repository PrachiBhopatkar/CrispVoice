# Hardened Runtime Audio Input Design

**Date:** 2026-08-08
**Status:** Approved for implementation planning

## 1. Context

CrispVoice v0.2.1 requests Microphone permission at launch and before capture. On a clean tester Mac, both requests return `false`, macOS shows no permission prompt, and CrispVoice never appears in System Settings under Privacy & Security > Microphone. Accessibility is trusted and Speech Recognition is authorized on the same machine.

The published v0.2.1 artifact has a valid `NSMicrophoneUsageDescription` and is signed with Hardened Runtime (`flags=0x10000(runtime)`), but it has no code-signing entitlements. Apple requires the Audio Input entitlement, `com.apple.security.device.audio-input`, for a Hardened Runtime app to record from the built-in microphone or use Core Audio input. The missing entitlement is therefore the release-blocking defect.

Local development testing did not expose the defect because `scripts/run-dev.sh` re-signs `DevBuild/CrispVoice.app` without Hardened Runtime. The stable development app reports `flags=0x0(none)`, while `scripts/build-release.sh` explicitly signs the public artifact with `--options runtime`. Development and release were exercising different security configurations.

## 2. Goals

- Give every Hardened Runtime CrispVoice application the Audio Input entitlement.
- Make the stable development signature exercise the same Hardened Runtime and microphone entitlement combination as the release signature.
- Reject a release or installation candidate when the Audio Input entitlement is absent or false.
- Preserve the existing stable code identities, bundle identifier, non-sandboxed architecture, privacy guarantees, and release verification policy.
- Verify the correction without tagging, pushing, or publishing a new release.

## 3. Non-goals

- Publishing, tagging, or pushing v0.2.2.
- Enabling the App Sandbox.
- Adding entitlements unrelated to microphone recording.
- Changing the permission-request UI or the `PermissionsManager` API.
- Resetting TCC permissions automatically or editing macOS privacy databases.
- Changing audio capture, transcription, Anthropic communication, or paste behavior.

## 4. Chosen Approach

Create one application entitlement file containing only:

```xml
<key>com.apple.security.device.audio-input</key>
<true/>
```

Reference that file from the XcodeGen target configuration. Explicitly pass the same file when shell scripts replace Xcode's signature, because a manual `codesign --force` operation must not rely on entitlements from a discarded signature.

Both release and stable development outer-app signatures will use Hardened Runtime and the Audio Input entitlement. Nested code will continue to be signed according to the existing policy without application-only entitlements.

This approach is preferred over patching only the release signer because it closes the dev/release testing gap. Removing Hardened Runtime was rejected because it would weaken the release security posture and contradict the current distribution design.

## 5. File Responsibilities

### `Sources/CrispVoice/App/CrispVoice.entitlements`

Owns the minimal application entitlement set. It contains `com.apple.security.device.audio-input = true` and no App Sandbox entitlement.

### `project.yml`

Points `CODE_SIGN_ENTITLEMENTS` at the entitlement file so Xcode-generated development builds use the same declared capability.

### `scripts/build-release.sh`

Passes the entitlement file explicitly while signing the outer release application with `--options runtime`. It fails before packaging if the entitlement file is unavailable.

### `scripts/run-dev.sh`

Passes `--options runtime` and the entitlement file when signing the stable development application. The existing stable Apple Development identity and designated-requirement checks remain unchanged.

### `scripts/verify-release-app.sh`

Extracts the signed application's entitlements into a private temporary file and requires `com.apple.security.device.audio-input` to be Boolean `true`. Missing, malformed, or false values reject the application.

### `scripts/install.sh`

Performs the same entitlement check using only system tools already permitted by the standalone installer. Verification occurs before the installed application is replaced.

### Shell regression tests

Release-build, verifier, installer, and stable-development launcher tests assert the new signing arguments and rejection behavior. Test fixtures distinguish a valid Boolean `true` entitlement from missing, malformed, string-valued, and false entitlements where those cases are observable through the verification boundary.

## 6. Signing and Verification Flow

```text
CrispVoice.entitlements
        |
        +--> XcodeGen target configuration
        |
        +--> run-dev outer-app codesign --options runtime --entitlements ...
        |       `--> stable DevBuild verification
        |
        `--> build-release outer-app codesign --options runtime --entitlements ...
                `--> verify-release-app entitlement check
                        `--> packaged artifact re-verification
                                `--> installer entitlement check before replacement
```

The release verifier and installer must inspect the entitlement embedded in the signed artifact, not merely the source plist. This ensures the check covers the exact binary users receive.

## 7. Failure Handling

- A missing source entitlement file stops development or release signing with a specific error.
- A failed entitlement extraction rejects the candidate.
- An absent, malformed, non-Boolean, or false Audio Input entitlement rejects the candidate.
- Installer rejection occurs before moving or replacing `~/Applications/CrispVoice.app`, preserving the previously installed version.
- No diagnostic output contains API keys, transcripts, audio, generated messages, certificate private material, or other secrets.

## 8. Testing Strategy

Implementation follows test-driven development:

1. Add shell tests that fail because current signing commands omit Hardened Runtime and/or the entitlement file.
2. Add verifier and installer tests that fail because candidates without the Audio Input entitlement are currently accepted.
3. Make the minimal signing and verification changes needed to pass.
4. Run all release-script and development-launcher shell suites.
5. Run `xcodegen generate` and the complete XCTest suite.
6. Run a clean Debug build.
7. Build a non-published development release and inspect the exact resulting app with `codesign` to confirm:
   - `flags=0x10000(runtime)`;
   - `com.apple.security.device.audio-input` is Boolean `true`;
   - `NSMicrophoneUsageDescription` remains present;
   - strict release verification succeeds.
8. Launch the stable development app twice and confirm its signature remains stable and Hardened Runtime retains the Audio Input entitlement.

The public clean-Mac permission prompt remains a release-candidate validation step for the future v0.2.2 publication. This implementation task does not publish or install a new public release on the tester Mac.

## 9. Security and Privacy Invariants

- App Sandbox remains disabled.
- Audio and transcripts remain on device.
- Runtime network traffic remains limited to `api.anthropic.com` with the user's own key.
- No telemetry or content-bearing logging is added.
- No secret, private key, model binary, or release artifact is committed.
- The Audio Input entitlement is the only new application entitlement.

## 10. Completion Criteria

The correction is ready for a later release only when:

- all focused shell regression tests pass;
- all XCTest tests pass;
- the clean Debug build succeeds;
- the non-published release artifact has Hardened Runtime and the Boolean Audio Input entitlement;
- both spec/plan conformance and code-quality reviews pass;
- the implementation is committed without a tag, push, GitHub Release, or tester-Mac installation.
