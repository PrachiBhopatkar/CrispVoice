# CrispVoice Self-Signed Early-Access Distribution Design

**Date:** 2026-08-01
**Status:** Approved for implementation planning

## 1. Context

CrispVoice's existing public-release direction assumes Apple Developer Program membership, Developer ID signing, and notarization. That path is deferred. The immediate audience is a small group of technical early adopters who are comfortable running a terminal installer and explicitly accepting a non-notarized application.

The repository and release downloads will be public. The release must support macOS 13 or later on both Apple Silicon and Intel Macs. This distribution change must not alter the app's runtime privacy model: the installed application has no developer backend, processes speech on-device, and sends rewrite requests only to Anthropic using the user's own API key.

## 2. Goals

- Provide a one-command installation and upgrade path from public GitHub Releases.
- Ship one universal application containing `arm64` and `x86_64` slices.
- Give successive releases a stable code identity without Apple Developer Program membership.
- Verify release integrity and identity before installing or replacing the application.
- Install without `sudo` and without adding a privileged helper, background service, or package installer.
- Preserve the existing app, settings, Keychain entry, and permissions during a successful upgrade whenever macOS accepts the stable code identity.
- Make the Gatekeeper bypass and its risks explicit before installation.

## 3. Non-goals

- Apple Developer ID signing or notarization.
- Mac App Store distribution.
- A graphical installer, DMG, PKG, Homebrew tap, or Sparkle update feed.
- Silent or unattended installation by default.
- Automatic approval of Microphone, Speech Recognition, or Accessibility permissions.
- Support for managed Macs whose organization blocks unidentified applications.
- Changes to CrispVoice's capture, transcription, rewrite, or paste behavior.

## 4. Decision

Distribute a universal Release build through public GitHub Releases. Sign the application with a persistent, long-lived, self-signed code-signing certificate controlled by the CrispVoice publisher. Install and upgrade it with a repository-owned shell script.

The self-signed identity does not make the app trusted by Gatekeeper and does not claim Apple verification. Its purpose is to establish continuity between CrispVoice releases so macOS and the installer can distinguish releases signed by the same publisher-controlled key from unrelated or accidentally ad-hoc-signed builds.

The initial trust anchor remains the public GitHub repository and the installer's pinned certificate fingerprint. Early adopters must knowingly accept that trust model.

## 5. Signing identity

The publisher creates a self-signed certificate suitable for code signing with a long validity period and a CrispVoice-specific common name. This is a one-time manual setup.

- The private key remains in the publisher's macOS Keychain.
- An encrypted offline backup is required before the first release.
- Private-key exports such as `.p12` files are ignored by Git and never stored in the repository, build output, or GitHub Actions.
- The SHA-256 fingerprint of the leaf certificate's DER representation is recorded in a version-controlled release configuration and pinned in the installer.
- Release tooling refuses to sign or package an app when the selected identity's fingerprint differs from the pinned value.
- The app is signed with the hardened runtime already configured by the project. Any nested code is signed explicitly from the inside out before the outer app bundle; release tooling does not use `codesign --deep` to perform signing.
- Signature verification may use deep verification to check the completed bundle.

Losing or rotating the key is a breaking distribution event. The installer must reject a release signed with a different identity until its pinned fingerprint is deliberately updated. A rotation must be documented because macOS may request privacy permissions again.

## 6. Release build and artifact

Add a release-building script that performs the following steps in order:

1. Validate the requested semantic version and expected Git tag.
2. Require a clean, tagged source revision so uncommitted files cannot enter a release accidentally.
3. Generate the Xcode project with XcodeGen.
4. Run the full unit test suite.
5. Build CrispVoice in Release configuration for macOS 13 or later with `arm64` and `x86_64` architectures and `ONLY_ACTIVE_ARCH=NO`.
6. Sign the completed code hierarchy with the expected self-signed identity and hardened runtime.
7. Verify code integrity, bundle identifier, version metadata, minimum macOS version, signing-certificate fingerprint, and both architectures.
8. Package the application with `ditto` as `CrispVoice-<version>-macos-universal.zip`.
9. Generate a SHA-256 checksum file.
10. Extract the ZIP into a fresh temporary directory and repeat the application checks against the packaged artifact.

Artifacts are written under a gitignored `dist/` directory. Publishing to GitHub is a separate, explicit action. Initial releases are built locally so the signing private key does not need to enter a CI system.

The GitHub Release contains:

- `CrispVoice-<version>-macos-universal.zip`
- `CrispVoice-<version>-macos-universal.zip.sha256`
- Release notes that identify the version as self-signed and non-notarized

The release process may include a helper command for `gh release create`, but it must not publish, push, change repository visibility, or create a release without an explicit operator action. Repository visibility must be confirmed as public before publishing the first early-access release.

## 7. Installer and upgrade flow

The public `scripts/install.sh` is compatible with the Bash version shipped by supported macOS releases. It uses `set -euo pipefail`, a private temporary directory created with `mktemp -d`, and a cleanup trap.

The user-facing command downloads the public installer from the repository and runs it. Before modifying the system, the installer displays a concise warning that CrispVoice is self-signed, is not notarized by Apple, and will require a scoped Gatekeeper bypass. It obtains confirmation from `/dev/tty` so confirmation works when the script itself is piped to Bash.

After confirmation, the installer:

1. Confirms the host is macOS 13 or later and required system tools are available.
2. Resolves the latest non-prerelease tag through GitHub's public `/releases/latest` redirect, validates the returned tag as a semantic version, and downloads that version's universal ZIP and checksum over HTTPS.
3. Verifies the SHA-256 checksum.
4. Extracts the archive only into its temporary directory.
5. Verifies that the extracted bundle:
   - is named `CrispVoice.app`;
   - has bundle identifier `com.crispvoice.app`;
   - contains both `arm64` and `x86_64` executable slices;
   - passes strict code-signature verification; and
   - is signed by the pinned self-signed certificate fingerprint.
6. Stops a running CrispVoice instance if needed.
7. Creates `~/Applications` when it does not exist.
8. Moves an existing `~/Applications/CrispVoice.app` to a temporary backup.
9. Moves the verified new app into place.
10. Removes `com.apple.quarantine` only from the installed CrispVoice bundle.
11. Launches CrispVoice.
12. Removes the previous-version backup after the launch command succeeds.

Running the same command again performs an upgrade. The bundle identifier and install path remain stable, so preferences and Keychain data are not removed. The installer never resets TCC permissions and never deletes application support data.

The early adopter remains responsible only for running the command, accepting the warning, granting macOS privacy permissions, and entering an Anthropic API key. If organizational policy still blocks the app, the installer explains that the user may need **Open Anyway** in System Settings or assistance from their administrator.

## 8. Failure handling and rollback

- A download, checksum, signature, identity, metadata, or architecture failure aborts before the installed app is touched.
- Temporary files are removed on exit.
- An upgrade retains the old app until the new bundle has passed all pre-installation checks.
- If moving or launching the new app fails, the installer restores the old app and exits nonzero.
- The installer never substitutes a differently signed release automatically.
- The installer prints specific, actionable errors without printing API keys, transcripts, messages, or other sensitive data.
- A first-time installation failure leaves no partial app in `~/Applications`.

## 9. Documentation changes

Update the README and release documentation to include:

- The one-command installation and upgrade workflow.
- A safer download-inspect-run alternative for users who do not want to pipe a script directly to Bash.
- The self-signed and non-notarized status.
- What the installer downloads, verifies, changes, and launches.
- Microphone, Speech Recognition, Accessibility, and API-key setup.
- Uninstall instructions that remove the app without deleting Keychain data unless the user explicitly requests that cleanup.
- Limitations on managed Macs.
- The future migration path to Developer ID signing and notarization.

The existing design specification must be amended so Apple Developer Program membership and notarization are a later public-distribution upgrade, not a prerequisite for this early-access channel.

## 10. Verification

Before accepting the work:

1. Generate the Xcode project and run the full XCTest suite.
2. Build the universal Release app and confirm `lipo` reports `arm64` and `x86_64`.
3. Confirm strict code-signature verification passes and the embedded signing fingerprint matches the pinned fingerprint.
4. Confirm the packaged ZIP extracts cleanly and passes the same checks.
5. Run syntax checks against all shell scripts and test them with the system Bash version.
6. Exercise a first installation into a clean test account.
7. Exercise an upgrade and a deliberately corrupted download; the corrupted artifact must be rejected while the installed version remains intact.
8. Exercise a release signed with the wrong identity; the installer must reject it.
9. Launch the Intel slice under Rosetta on Apple Silicon when available, and obtain a smoke test from an actual Intel Mac before claiming full Intel support.
10. Install two successively changed builds signed by the same certificate and confirm whether Microphone, Speech Recognition, and Accessibility grants persist. If they do not, document the re-approval behavior rather than claiming seamless permission retention.
11. Repeat the existing privacy smoke test: the installed app's only outbound runtime destination is Anthropic. Installer traffic to GitHub is documented separately and occurs only during installation or upgrade.

The release remains an early-access build until the clean-install, upgrade, rollback, architecture, permission-continuity, and privacy checks have been observed on real machines.

## 11. Future migration

When Apple Developer Program membership becomes appropriate, keep GitHub Releases and the installer interface but replace the self-signed identity with Developer ID signing and notarization. That migration changes the signing identity, so it requires a deliberate installer update, clear release notes, and testing for renewed privacy-permission prompts.
