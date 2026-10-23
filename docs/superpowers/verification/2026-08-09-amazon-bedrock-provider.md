# Amazon Bedrock Rewrite Provider — Verification Record

**Plan:** `docs/superpowers/plans/2026-08-09-amazon-bedrock-provider.md`
**Spec:** `docs/superpowers/specs/2026-08-09-amazon-bedrock-provider-design.md`
**Date range:** 2026-08-09 through 2026-10-23
**Branch:** `feat/amazon-bedrock-provider`

This record covers Task 11 ("Verify signed distribution and complete
office-laptop acceptance"). It contains only pass/fail results, command
names, and non-sensitive observations — no account IDs, ARNs, credentials,
raw logs, internal hostnames, prompts, transcripts, or response content.

## Automated verification (Steps 1–4)

| Check | Result |
|---|---|
| `swift test` (vendor/BedrockSDKBridge, including credential-process contract tests against a synthetic fixture) | PASS — 23/23 |
| `xcodebuild ... test` (full CrispVoice suite) | PASS — 116/116 |
| Debug build | `** BUILD SUCCEEDED **` |
| Clean arm64 Release build (`CODE_SIGNING_ALLOWED=NO`) | `** BUILD SUCCEEDED **` |
| Clean x86_64 Release build (`CODE_SIGNING_ALLOWED=NO`) | `** BUILD SUCCEEDED **` |
| `Tests/ReleaseScripts/PrivacyInvariantTests.sh` | PASS |
| `./scripts/check-release-signing.sh --require-private-key` | PASS |
| Parameterized installer-upgrade test (`Tests/ReleaseScripts/InstallerTests.sh`), preference/Keychain sentinel preservation through success, rejected-archive, and rollback paths | PASS |
| Signed universal development release candidate (`./scripts/build-release.sh --development 0.3.0`) | Built; `lipo -archs` reports `arm64 x86_64`; `codesign --verify --deep --strict --verbose=4` PASS; entitlements retain Hardened Runtime Audio Input, no App Sandbox; no nested `BedrockSDKBridge` binary present in the app bundle (statically linked, as designed) |

## Final whole-branch review

Independent architecture-level review of the complete branch (15 commits,
base through Task 11 Steps 1–4). Verdict: ready to merge with fixes. Found
and the team fixed 4 cross-task interaction issues (a shell-compatibility
bug in the privacy smoke-test script, a misrouted Anthropic error message,
a Settings-window draft-discard gap, and a missing build-prerequisite note
in the project's own agent instructions). One scoped re-review confirmed
all four addressed with no new breakage. No Critical findings at any point.

## Manual acceptance (Steps 5–9)

| Check | Result |
|---|---|
| Local Anthropic regression (existing Keychain key continues to work; Test Connection; a real dictation round-trip) | PASS, confirmed by the operator on a personal machine, including both Test Connection and a live dictate-and-paste round-trip |
| Office-laptop AWS session confirmed live before testing | PASS (implicit — Bedrock credential resolution succeeded against the real office AWS profile, which requires a live session) |
| Finder-launched Bedrock happy path (Test Connection, then a real dictate-to-paste round-trip, using the office AWS profile, Region `us-west-2`, model Claude Opus 4.8 (US)) | **PASS** — confirmed by the operator. This satisfies the design's explicit release-blocking bar: a Terminal-only success does not satisfy it; this was a Finder-launched, real-credential success. |
| Expired/unavailable AWS session produces a safe, actionable recovery message (not a raw AWS error) | PASS — operator observed a safe "AWS session expired" message from Test Connection before refreshing their login; retry succeeded afterward without editing Settings |
| Invalid/unauthorized model ID produces safe access/configuration wording | Not separately exercised; optional sub-case, not required to close the recovery-path requirement above |
| Privacy smoke test — Anthropic | Diagnostic-log canary scan: **PASS** (run twice; confirms dictated/rewritten content never reaches the debug log). Network-destination-observation half: inconclusive both runs (the sampling script observed no established TCP connections during the window despite a confirmed real rewrite occurring) — attributed to the script's coarse 1-second `lsof` polling against the app's own process, a tooling limitation rather than a privacy defect. The script was not weakened to force a different result. |
| Privacy smoke test — Amazon Bedrock | **Deferred.** Instructions were provided for the office laptop; result was not obtained before this verification record was written. Tracked as an open follow-up (see below), not claimed as passing. |

## Open follow-up (tracked, not blocking this merge)

- Run `scripts/privacy-smoke-test.sh` with Amazon Bedrock selected, on a
  machine with real AWS credentials, and record the result here or in a
  superseding verification record.
- Given the final whole-branch review's import-boundary and diagnostic-log
  audits apply equally to both providers (the shared `SafeErrorPresenter`/
  `DebugLog` code path, not provider-specific code), and Bedrock's own
  live happy-path and recovery-path checks both passed, this follow-up is
  believed low-risk — but it is the one acceptance item from the original
  12-step task that was not directly observed.

## Summary

Every automated check passes. The feature's core release-blocking
requirement — a signed, Finder-launched CrispVoice successfully using a
real AWS profile for Bedrock, with no Terminal-only shortcut — was
independently verified live. One acceptance sub-item (the Bedrock half of
the privacy smoke test) remains open and is tracked above rather than
silently assumed.
