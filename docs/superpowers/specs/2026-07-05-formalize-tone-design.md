# CrispVoice — Formalize Tone — Design Spec

**Date:** 2026-07-05
**Status:** Approved for planning
**Author:** Varad + Claude

---

## 1. One-line summary

Replace the existing **Shorter** tone button with a new **Formal** tone that rewrites the dictated message as a formal, professional piece of writing (complete sentences, no contractions, a neutral greeting/sign-off) — so CrispVoice produces good output for email-style contexts (Outlook, Gmail) as well as chat.

## 2. Problem & context

CrispVoice's paste target is not restricted to Slack: `captureTargetApplication()` (`AppDelegate.swift:209`) already captures whatever app is frontmost when the hotkey is pressed and pastes the crisped text back into that app, whatever it is. So CrispVoice already works mechanically in Teams, Outlook, Notes, or any text field.

What doesn't yet adapt is the **rewrite style**. `CrispPrompt.system` is hardcoded to Slack-message conventions, and the four tone buttons (Neutral, Shorter, Direct, Warmer) are all chat-register. There is no way to get email-appropriate output (fuller sentences, formal word choice, a greeting/sign-off) without manually editing the pasted text afterward.

### Rejected approach: automatic app/context detection

An earlier direction for this considered detecting the target app's bundle ID (e.g., Outlook desktop) and auto-switching rewrite style. This was rejected for the MVP:

- Native apps (Slack, Teams, Outlook desktop) have stable bundle IDs, but **Gmail and Outlook-web run inside a general-purpose browser** — the frontmost app is just "Safari" or "Chrome," indistinguishable from any other site without inspecting the active tab's URL/title via Accessibility APIs. That's a materially larger, more invasive feature (extra permissions, per-browser quirks) than this change warrants.
- A manual tone button is simpler, fully explicit, consistent with how Shorter/Direct/Warmer already work, and needs no detection logic of any kind.

This spec covers only the manual-button approach. Bundle-ID or browser-tab detection is explicitly out of scope (see Non-goals).

## 3. Design

### 3.1 Tone enum (`Sources/CrispVoice/Crisp/CrispPrompt.swift`)

Remove `.shorter`. Add `.formal`.

```swift
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
```

Rationale for dropping Shorter rather than Direct: Shorter (aggressive length reduction) and Direct (cut hedging, get to the point) overlap heavily in practice — Direct is the more distinct concept of the two, so it stays.

### 3.2 System prompt exception (`CrispPrompt.system`)

Current rule (`CrispPrompt.swift:30`):

> "Do not add greetings or sign-offs that weren't intended."

This blanket rule conflicts with Formal's need to add a generic greeting/sign-off. Change it to a single named exception rather than branching logic in `CrispPrompt.system`:

> "Do not add greetings or sign-offs that weren't intended, unless the tone instruction below explicitly calls for one."

`CrispPrompt.system`'s signature and all other behavior (variant count, JSON-only output, "do not invent facts" rule) are unchanged. The exception is entirely carried by `Tone.formal.instruction`'s own wording, keeping the system prompt tone-agnostic.

### 3.3 UI (`Sources/CrispVoice/UI/SuggestionView.swift`)

`toneButton` calls in the tone `HStack` (currently `SuggestionView.swift:73-75`) change from:

```
Shorter, Direct, Warmer, Regenerate
```

to:

```
Direct, Warmer, Formal, Regenerate
```

No new `@Published` state, no new view structure — `model.onTone(tone)` and the existing rerun path (`AppDelegate.rerun(tone:)`) are reused exactly as they work today for the other three tones.

### 3.4 Testing

- `Tests/CrispVoiceTests/CrispPromptTests.swift`: remove/replace any assertion tied to `.shorter`; add a test asserting `Tone.formal.instruction` mentions formality/complete sentences/greeting.
- Add/keep a test asserting `CrispPrompt.system(...)` still contains the "do not invent facts" language, to confirm the exception wording didn't weaken the existing anti-hallucination rule.
- No new test infrastructure needed — no networking, no detection logic, no new mocks.

## 4. Non-goals

- No frontmost-app or bundle-ID-based tone/format auto-detection.
- No browser tab/URL inspection to distinguish Gmail/Outlook-web from other sites.
- No per-app configuration surface in Settings.
- No changes to `Inserter`, `captureTargetApplication()`, or any paste-targeting logic — this spec only changes rewrite style, not where text is pasted.

## 5. Open questions / future extensions

- If real usage shows the target app *is* reliably knowable often enough to be worth auto-preselecting Formal (e.g., for Outlook desktop specifically, which has a stable bundle ID unlike Gmail), that could be a small, separate follow-up spec — not part of this change.
- Greeting/sign-off text is intentionally generic ("Hi," / "Best,") since CrispVoice has no reliable source for a recipient's name.
