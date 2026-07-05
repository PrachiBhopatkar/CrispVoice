# Formalize Tone Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace CrispVoice's "Shorter" tone button with a "Formal" tone that rewrites dictated messages as formal, professional writing (complete sentences, no contractions, generic greeting/sign-off), so the crisp rewrite is appropriate for email-style contexts as well as chat.

**Architecture:** No new components. `Tone` (an enum in `CrispPrompt.swift`) drives both the Claude prompt instruction and the SwiftUI tone buttons in `SuggestionView.swift`; this plan swaps one case for another in that enum, adjusts one sentence in the shared system prompt to permit Formal's greeting/sign-off, and updates the corresponding UI button. No detection logic, no new state, no new files.

**Tech Stack:** Swift 5.9+, XCTest, `xcodebuild` (no simulator — macOS unit test destination).

## Global Constraints

- Per spec (`docs/superpowers/specs/2026-07-05-formalize-tone-design.md`): no app-detection or bundle-ID logic of any kind — this is a manual tone button only.
- `Tone` must remain exactly 4 cases: `neutral, direct, warmer, formal` (drop `.shorter`; do not add a 5th case).
- The system prompt's existing "do not invent facts" rule and JSON-output contract must remain unchanged — only the greeting/sign-off sentence changes.
- `Tone` is not persisted anywhere (confirmed: no `Tone(rawValue:)` call in the codebase), so removing `.shorter` needs no migration handling.

---

### Task 1: Replace Shorter tone with Formal tone (prompt + UI)

**Files:**
- Modify: `Sources/CrispVoice/Crisp/CrispPrompt.swift`
- Modify: `Sources/CrispVoice/UI/SuggestionView.swift`
- Test: `Tests/CrispVoiceTests/CrispPromptTests.swift`

**Interfaces:**
- Consumes: existing `Tone: String, CaseIterable` enum and `CrispPrompt.system(variantCount:) -> String` / `CrispPrompt.user(transcript:tone:) -> String` signatures — unchanged by this task.
- Produces: `Tone.formal` case (replacing `Tone.shorter`), consumed by `SuggestionView`'s `toneButton(_:_:)` helper and by `AppDelegate.rerun(tone:)` exactly like the other three tones — no changes needed in `AppDelegate.swift`.

Both files must change together: `SuggestionView.swift` currently references `.shorter`, so the project will fail to compile (and therefore fail to test) if `CrispPrompt.swift` is edited alone. This task treats them as one atomic change.

- [ ] **Step 1: Write the failing tests**

Add these three tests to `Tests/CrispVoiceTests/CrispPromptTests.swift`, inside the existing `CrispPromptTests` class (after `test_user_embedsRawTranscriptAndTone`):

```swift
    func test_formalTone_instructsFormalLanguageAndGreeting() {
        let instruction = Tone.formal.instruction.lowercased()
        XCTAssertTrue(instruction.contains("formal"))
        XCTAssertTrue(instruction.contains("complete sentences"))
        XCTAssertTrue(instruction.contains("greeting"))
    }

    func test_user_embedsFormalToneInstruction() {
        let u = CrispPrompt.user(transcript: "can u send the report by friday", tone: .formal)
        XCTAssertTrue(u.contains("can u send the report by friday"))
        XCTAssertTrue(u.lowercased().contains("formal"))
    }

    func test_system_allowsGreetingExceptionForToneInstruction() {
        let s = CrispPrompt.system(variantCount: 3).lowercased()
        XCTAssertTrue(s.contains("unless the tone instruction below explicitly calls for one"))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test`
Expected: FAIL to build — `type 'Tone' has no member 'formal'` (referenced by the new tests). This is a compile-time failure, which `xcodebuild test` reports as a build failure rather than a test failure; that is the expected "red" state for this step.

- [ ] **Step 3: Replace the `Tone` enum and system prompt in `CrispPrompt.swift`**

Replace the full contents of `Sources/CrispVoice/Crisp/CrispPrompt.swift` with:

```swift
import Foundation

enum Tone: String, CaseIterable {
    case neutral, direct, warmer, formal

    var instruction: String {
        switch self {
        case .neutral:
            return "Keep a natural, professional tone."
        case .direct:
            return "Make it direct and to the point."
        case .warmer:
            return "Make it warmer and friendlier."
        case .formal:
            return "Rewrite as a formal, professional message. Use complete sentences, " +
                   "no contractions, and precise word choice. Add a brief, neutral greeting " +
                   "and sign-off even if none was dictated."
        }
    }
}

enum CrispPrompt {
    static func system(variantCount: Int) -> String {
        precondition(variantCount > 0, "variantCount must be positive")

        return """
        You rewrite rough, dictated Slack messages into crisp, clear ones.
        The input is a raw speech-to-text transcript and may contain dictation errors, \
        obvious transcription errors, non-words, filler words, and accent-related mistranscriptions — \
        infer the intended meaning from context, repair obvious transcription errors and non-words, \
        and fix them.
        Rewrite it to be concise, well-punctuated, and ready to send in Slack. Do not add greetings \
        or sign-offs that weren't intended, unless the tone instruction below explicitly calls for one. \
        Preserve the user's intent and any concrete details \
        (names, dates, links). Preserve facts. Do not invent details, claims, commitments, or context \
        that are not supported by the transcript.
        Return ONLY valid JSON of the form: {"variants": ["...", "..."]} with exactly \(variantCount) \
        distinct variants, best first. No prose outside the JSON.
        """
    }

    static func user(transcript: String, tone: Tone) -> String {
        return """
        Tone: \(tone.instruction)

        Raw transcript:
        \"\"\"
        \(transcript)
        \"\"\"
        """
    }
}
```

- [ ] **Step 4: Update the tone buttons in `SuggestionView.swift`**

In `Sources/CrispVoice/UI/SuggestionView.swift`, find this block (inside the `if model.showsVariantButtons` section of `SuggestionView.body`):

```swift
            if model.showsVariantButtons {
                HStack(spacing: 6) {
                    toneButton("Shorter", .shorter)
                    toneButton("Direct", .direct)
                    toneButton("Warmer", .warmer)
                    Button("Regenerate") { model.onRegenerate() }
                }
                .font(.caption)
            }
```

Replace it with:

```swift
            if model.showsVariantButtons {
                HStack(spacing: 6) {
                    toneButton("Direct", .direct)
                    toneButton("Warmer", .warmer)
                    toneButton("Formal", .formal)
                    Button("Regenerate") { model.onRegenerate() }
                }
                .font(.caption)
            }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test`
Expected: `** TEST SUCCEEDED **` — all `CrispPromptTests` pass (including the 3 new tests and the 2 pre-existing ones), and every other existing test target (`PasteboardTests`, `AudioConverterTests`, `CrispResultTests`, `AnthropicClientTests`, `CrispEngineTests`, `KeychainStoreTests`, `PreferencesTests`, `SuggestionModelTests`, `TranscriberTests`, `PermissionsManagerTests`) still passes since none of them reference `Tone`.

- [ ] **Step 6: Build and manually verify the panel**

Run:
```bash
xcodegen generate
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

Then launch the app (`open` the built `.app` as in prior phases), dictate a message, and confirm the suggestion panel's tone row now reads **Direct · Warmer · Formal · Regenerate** (no "Shorter"). Click **Formal** and confirm the regenerated variant reads as a formal message with a greeting/sign-off (e.g., "Hi," / "Best,") even though none was dictated.

- [ ] **Step 7: Commit**

```bash
git add Sources/CrispVoice/Crisp/CrispPrompt.swift Sources/CrispVoice/UI/SuggestionView.swift Tests/CrispVoiceTests/CrispPromptTests.swift
git commit -m "feat: replace Shorter tone with Formal tone"
```

---

**Plan complete.** This is the only task — per the design spec's non-goals, there is no detection logic, no Settings surface, and no other file touches in scope.
