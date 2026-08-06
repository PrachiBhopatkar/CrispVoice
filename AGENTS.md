# AGENTS.md — Working Agreement for CrispVoice

You are implementing **CrispVoice**, a native macOS menu-bar app. Read this file fully before doing anything, then follow it exactly.

## What you're building (one paragraph)

On a global hotkey, the app records the mic, transcribes **on-device** with `whisper.cpp` (via SwiftWhisper), rewrites the text into a crisp Slack message using the user's **own** Anthropic API key, and pastes the result into the focused Slack compose box (clipboard + synthesized ⌘V) so it posts **as the user**. No Slack app, no developer backend.

## Source of truth

- **Design spec:** `docs/superpowers/specs/2026-06-12-crispvoice-design.md`
- **Implementation plan (your task list):** `docs/superpowers/plans/2026-06-12-crispvoice-mvp.md`

The plan is the authoritative, ordered task list (Phases 0–3 = the MVP). Implement it **in order, one task at a time.** Do not skip ahead or batch tasks.

## Hard invariants (never violate)

1. **No developer backend, ever.** The only outbound network call the app makes is to `api.anthropic.com`, with the user's own key. No telemetry, analytics, or logging that contains audio, transcripts, or message text.
2. **Privacy:** audio and transcripts never leave the device. Transcription is fully local (whisper.cpp).
3. **Do NOT enable the App Sandbox.** The app needs Accessibility (keystroke synthesis) and direct distribution.
4. **Never commit secrets or large binaries.** The Anthropic key lives only in the macOS Keychain (Phase 3) or a dev env var before that — never in source. `.gitignore` already excludes `*.bin`, `*.gguf`, `.env`, `*.key`, `Models/`, and build output. Respect it.
5. **One commit per completed task**, using the commit message given in the plan's final step for that task.

## Execution methodology — Subagent-Driven Development

Drive the build with **subagent-driven development**: dispatch a fresh subagent for each task, then review its work before moving on.

**If you have the `superpowers` skills installed, USE them:**

- `superpowers:subagent-driven-development` — the overall loop (fresh subagent per task + two-stage review). **Start here.**
- `superpowers:test-driven-development` — for every task that has unit-testable logic, write the failing test first, watch it fail, then implement (the plan is already written this way — follow it).
- `superpowers:requesting-code-review` — after a task's code is written, request review before accepting it.
- `superpowers:receiving-code-review` — when acting on review feedback; verify suggestions rather than applying blindly.
- `superpowers:verification-before-completion` — before declaring ANY task "done," run the verification commands and confirm the actual output. Evidence before assertions.
- `superpowers:systematic-debugging` — the moment a test fails unexpectedly or a manual step misbehaves, use this before guessing at fixes.
- `superpowers:using-git-worktrees` — optional, if you want to isolate the work in its own worktree.
- `superpowers:finishing-a-development-branch` — when the MVP (Phase 3) is complete, to decide how to integrate.

**If you do NOT have those skills,** follow the equivalent discipline manually (described in "Per-task loop" below).

## Per-task loop (run this for EVERY task in the plan)

1. **Dispatch a fresh subagent** scoped to exactly one task from the plan. Give it: the task's full text, this AGENTS.md, and the relevant spec section. Do not let one subagent do multiple tasks.
2. **Implement via TDD where the task specifies tests:** write the failing test → run it, confirm it fails for the stated reason → write the minimal code → run it, confirm it passes. For system/UI tasks with no unit test, implement and then perform the **manual verification step exactly as written** in the plan.
3. **Test after the task** — always run the full unit suite, not just the new test:
   ```bash
   xcodegen generate
   xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test
   ```
   All previously-passing tests must still pass (no regressions). For tasks ending in a build-only or manual step, also run a clean build:
   ```bash
   xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -configuration Debug build
   ```
   The expected result is `** BUILD SUCCEEDED **` / all tests green.
4. **Two-stage review before accepting the task:**
   - **Stage A — Spec/plan conformance:** does the change implement what the task asked, with the exact types/signatures the plan defines? Check naming consistency against earlier tasks (e.g., `Tone`, `CrispResult.variants`, `complete(system:user:maxTokens:)`).
   - **Stage B — Code review:** correctness, error handling, no leaked secrets, no backend/telemetry creep, no sandbox, focused files. Use `superpowers:requesting-code-review` if available, otherwise review against this checklist.
   Fix anything found, re-run tests, then accept.
5. **Verify, then commit.** Only after tests/build/manual step actually pass (confirmed by real output — not assumption) do you commit using the plan's commit command for that task.
6. **Respect phase gates.** Do not start the next phase until the current phase's gate (stated in the plan) is met:
   - **Phase 0 gate:** the hotkey reliably pastes fixed text into the live Slack desktop app.
   - **Phase 1 gate:** a spoken sentence reliably becomes a crisp message pasted into Slack (hardcoded/env key).
   - **Phase 2 gate:** the floating panel shows variants, tone buttons re-crisp, inline edit works, Slack stays frontmost.
   - **Phase 3 gate (MVP):** key loaded from Keychain (no hardcoded secret), whisper model selectable, permissions guided, full loop works.

## Definition of done (per task)

A task is done only when ALL are true:
- Its tests/build pass (verified by real command output).
- Any manual verification step in the task has been performed and observed to succeed.
- No regression in the existing test suite.
- Code reviewed (both stages) and clean.
- Committed with the plan's commit message.

## Build & test reference

```bash
# First-time toolchain
brew install xcodegen
./scripts/download-model.sh base    # downloads Models/ggml-base.bin (gitignored)

# Generate the Xcode project from project.yml (re-run after adding files)
xcodegen generate

# Build
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -configuration Debug build

# Test
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test

# Build, sign, verify, and launch the stable development copy.
./scripts/run-dev.sh
```

Do not launch CrispVoice directly from Xcode DerivedData; that build is ad-hoc signed and invalidates Accessibility permission after rebuilds.

For end-to-end tasks before Phase 3, supply the key via env: launch with `ANTHROPIC_API_KEY` set (see plan Task 1.8).

## Known stack caveats

The plan pins specific third-party APIs (SwiftWhisper's `transcribe(audioFrames:)`, HotKey's `keyDownHandler`, a few AVFoundation calls). These are real packages, but exact signatures may have drifted. If a signature doesn't match the installed version, adapt the call to the installed API — keep the behavior identical and the tests green. Do not swap out the libraries or the architecture.

## When the MVP is complete

After Phase 3 passes, run the full suite, do the privacy smoke test (Task 3.6 — confirm the only outbound connection is `api.anthropic.com`), then push and tag `v0.1.0-mvp`. Phases 4 (notarized public release) and 5 (managed/marketplace) are out of scope here and will get their own plans.
