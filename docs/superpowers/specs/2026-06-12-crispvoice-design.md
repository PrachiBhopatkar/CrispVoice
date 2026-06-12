# CrispVoice — Design Spec v1

**Date:** 2026-06-12
**Status:** Approved for planning
**Author:** Prachi (PM) + Claude

---

## 1. One-line summary

A macOS menu-bar companion that turns rough, dictated speech into a crisp, concise Slack message you send **as yourself** — in any workspace, with **no Slack app install**, **no admin approval**, and **no developer backend** (your audio and transcripts never leave your Mac).

## 2. Problem & value proposition

Writing good Slack messages is slow, and most dictation tools mangle accented speech. The value of CrispVoice is **usability, speed, and message quality**: read a message, invoke CrispVoice right where you are, dictate a rough reply, and send a polished version on the spot — without leaving the conversation, copying across windows, or depending on anyone's IT admin.

The differentiator is the pairing of **accent-robust on-device transcription** (so your words are captured accurately despite an accent) with a **crisp rewrite** (so the message is concise and well-written). Transcription happens locally; the rewrite is done by the user's own Claude.

## 3. Target users

- **Primary (v1):** The author — a PM who sends many Slack messages daily, often in a **company workspace where they are not an admin** and cannot get apps approved.
- **Secondary (public BYOK release):** Other individuals (PMs, engineers, early adopters) who download the app and supply their own Anthropic API key.

## 4. Key constraints that shaped the design

These were discovered during brainstorming and are load-bearing:

1. **Slack apps cannot intercept the native compose box** or rewrite a message in flight. Any Slack-app approach is necessarily a *capture → draft → approve → post* loop.
2. **Every in-Slack surface requires the app to be installed in that workspace** — slash commands, message actions, ephemeral messages, Block Kit buttons all need a workspace install, which is exactly what a company admin gates.
3. **The author cannot rely on company-admin approval.** Therefore the product must work **without installing anything into the company's Slack workspace.**
4. **The author uses the Slack desktop app** (Electron), not Slack in a browser — so a browser extension cannot reach it.
5. **Privacy is a hard requirement.** The developer's app must never receive the user's audio or transcribed text. Everything stays on the user's machine except the rewrite request the user chooses to send to their *own* Claude.

The only architecture satisfying all of these is a **client-side macOS companion** that operates at the UI layer (like Grammarly's desktop app), not the Slack API layer, with **on-device transcription** and **no developer backend**. Slack never knows CrispVoice exists, and neither does the developer's infrastructure.

## 5. Architecture overview

A native macOS **menu-bar app**. No server, no Slack API, no OAuth, and **no developer backend** — ever.

```
[Global hotkey]
      │
      ▼
[Audio capture]  (on device)
      │  audio buffer — never leaves the Mac
      ▼
[whisper.cpp local STT]  (on device)        ← accent-robust transcription, fully offline
      │  transcribed text — never leaves the Mac
      ▼
[Crisp engine]  ──HTTPS, user's own API key──▶  [Anthropic API / Claude]
      │  (request goes user's machine → Anthropic directly; no developer server in the path)
      │  crisp draft + tone variants
      ▼
[Suggestion panel over the thread]  ── user picks / edits ──▶
      │  chosen text
      ▼
[Paste into focused Slack compose box]  (Accessibility + clipboard)
      │
      ▼
[User presses Enter → posted as themselves]
```

### Core flow ("Flow ii" — dictate into CrispVoice, then it drops the result in)

1. User presses the **global hotkey**. A small CrispVoice panel opens over the active thread and **audio recording starts** (the app captures the mic directly — no dependency on macOS system Dictation).
2. User dictates a rough reply; presses the hotkey again (or a stop key) to finish.
3. **`whisper.cpp` transcribes the audio locally**, on-device, to text. No network call.
4. CrispVoice sends that text to **Claude** (via the user's own API key, direct from the user's machine) to (a) clean up any residual errors and (b) rewrite it concisely, returning a crisp draft plus tone options.
5. User picks a variant (`Shorter · Direct · Warmer · Regenerate`) or quick-edits inline.
6. CrispVoice **pastes the chosen text into the Slack compose box**.
7. User presses **Enter** → the message posts **as themselves**, natively.

**Why Flow ii over "dictate into Slack then crisp in place":** the app only ever has to *write* into Slack's compose box (reliable), never *read* a rich-text Electron editor (fiddly). Capturing audio directly (rather than relying on macOS Dictation) also removes any dependency on the system Dictation shortcut and gives full control of the recording lifecycle.

## 6. Components

| Component | Responsibility | Notes |
|---|---|---|
| **Menu-bar app shell** | Lives in the menu bar; owns lifecycle, preferences window, status. | Native Swift recommended. |
| **Hotkey manager** | Registers a configurable global hotkey; starts/stops capture. | |
| **Audio capture** | Records mic audio to an in-memory/local buffer while recording. | Requests macOS Microphone permission. Audio never leaves the device. |
| **Local STT (`whisper.cpp`)** | Transcribes the captured audio on-device to text. | Bundled model (e.g. `small`/`medium`/`large-v3`); accent-robust; fully offline. |
| **Crisp engine** | Sends transcribed text to Claude with a tuned prompt; parses crisp draft + variants. | Uses the user's own key, direct to Anthropic. Provider-pluggable internally. |
| **Suggestion panel** | Renders crisp variants + tone buttons; supports inline edit. | The visible "see all options right there" surface. |
| **Inserter** | Pastes chosen text into the focused field via Accessibility + clipboard (save/restore clipboard). | The de-risked core capability (Phase 0). |
| **Settings / Keychain store** | Stores the Anthropic API key in macOS Keychain; stores hotkey, model, and tone prefs. | Never hardcode keys. |
| **Onboarding** | First-run: grant Microphone + Accessibility → set hotkey → paste & validate API key → test message. | |

### Tech stack

- **Native Swift** for the app — cleanest path for menu-bar, global hotkey, Accessibility, mic capture, and floating panels.
- **`whisper.cpp`** (MIT-licensed, free, commercial-OK) for on-device transcription, running natively on Apple Silicon (Metal/Core ML). Whisper model weights are also MIT-licensed and free.
- **Anthropic API (Claude)** as the crisp engine — called directly from the user's machine with the user's own key. The crisp engine is written so another provider could be added later, but v1 ships Claude only.
- **Tauri** is a documented fallback if web-tech is strongly preferred, but it complicates Accessibility/hotkey/mic work and is **not** recommended.

## 7. Transcription decision (local `whisper.cpp`)

- **Chosen (v1): local `whisper.cpp`.** On-device, accent-robust, free, private, and — because it needs no API key — keeps BYOK to a **single Anthropic key**. Costs are non-monetary: app size (bundled model: `small`/`medium` ≈ hundreds of MB, `large-v3` ≈ 1–3 GB) and a second or two of on-device compute per clip. Model size vs. accuracy is a tunable choice; start with `small`/`medium` and offer `large-v3` for users who want maximum accent accuracy.
- **Optional dev quick-start only:** during early development, a cloud STT (`gpt-4o-transcribe`) can stand the loop up faster, but it requires a second (OpenAI) key and sends audio off-device, so it is **not** part of the shipped v1 — `whisper.cpp` ships in the first release.
- **Dropped:** macOS system Dictation (weak accent accuracy; no public API to start it; relinquishes control of the capture lifecycle).

## 8. Privacy & data flow

Privacy is a first-class requirement, satisfied *by construction* because there is **no developer backend**:

- **Audio** is captured on the user's Mac and **never leaves it**.
- **Transcription** runs **on-device via `whisper.cpp`** — no network call, so the developer never receives the text.
- **The crisp rewrite** is the *only* network call. It goes **directly from the user's machine to Anthropic, authenticated with the user's own API key** — it does **not** pass through any developer server (none exists). This is identical to the user using Claude directly, which their company already permits.
- **The developer (Prachi) never sees, stores, logs, or proxies** any user audio, transcript, message text, or API key.
- **No content-bearing telemetry, ever.** If anonymous crash/usage metrics are added later, they must exclude all message content. Principle: *nothing leaves the device except the user-initiated Claude call.*
- **Honest caveat:** Anthropic does receive the text being rewritten (unavoidable when Claude does the rewriting), but only under the user's own key, direct from their machine. Anthropic's API does not train on API inputs and has limited/zero retention.
- **Future option (out of scope for v1):** a fully-offline mode that uses a *local* LLM for the rewrite too, so even the crisp step never touches the network.

This posture is also a **selling point**: "CrispVoice has no servers; your audio and transcripts never leave your Mac; the only thing sent is the text you choose to crisp, to your own Anthropic key."

## 9. Distribution model (BYOK)

- **Bring Your Own Key.** Users download the app, open Settings, and paste **their own Anthropic API key**, stored in their macOS Keychain. The app calls Claude directly with it. (Thanks to local `whisper.cpp`, this is the **only** key required.)
- Keys stay on each user's machine. The author **never sees, stores, or proxies** anyone's key or traffic. Each user is billed by Anthropic for their own usage — **zero cost and zero liability** to the author.
- **Channel:** direct download (notarized DMG / GitHub Releases). **Not** the Mac App Store — App Store sandboxing forbids the Accessibility access CrispVoice requires (the same reason Grammarly's desktop app is a direct download).

### Apple Developer Program

- Required **only for Phase 4 (public release)** to code-sign + notarize so the app opens cleanly past Gatekeeper. Cost: **$99/year**.
- **Phases 0–3 need zero Apple money** — a free Apple ID suffices for local build and personal/tester use (testers do a one-time Gatekeeper bypass).
- Notarization matters extra here because the app requests Accessibility and Microphone permissions; an "unverified developer" warning on top of that would destroy user trust.

## 10. Phased build plan

- **Phase 0 — De-risk spike (½–1 day).** Prove the single riskiest capability: from a global hotkey, reliably paste text into the focused **Slack desktop** compose box via Accessibility + clipboard (save/restore the user's clipboard). Everything else depends on this working.
- **Phase 1 — Core loop (author only).** Hotkey → record audio → `whisper.cpp` transcribe on-device → Claude crisp (single best output) → paste into Slack. API key hardcoded for now. Goal: the loop works end to end for the author, fully on-device except the Claude call.
- **Phase 2 — Quality & control.** Multiple variants + tone buttons (`Shorter · Direct · Warmer · Regenerate`), the polished over-thread suggestion panel, prompt tuning for cleanup/concision, edit-before-send, selectable whisper model size.
- **Phase 3 — Settings & onboarding.** Keychain API-key entry + validation, configurable hotkey, Microphone + Accessibility permission flows, preferences window.
- **Phase 4 — Public BYOK release.** Apple Developer Program, code-sign + notarize, download page / GitHub Releases, quickstart docs, privacy statement, auto-update (Sparkle).
- **Phase 5 — Optional later.** (a) Managed backend + subscription (no BYOK) for non-technical mass market; (b) a separate **Slack-native Marketplace app** for richer in-Slack context; (c) a fully-offline mode (local LLM for the rewrite). All distinct tracks beyond v1.

## 11. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Pasting into Slack's Electron rich-text compose box is unreliable. | **Phase 0 spike settles this before any other build.** Clipboard + simulated paste is the robust fallback to direct Accessibility value-setting. |
| `whisper.cpp` model size vs. accuracy/app-size tradeoff. | Ship a mid-size model (`small`/`medium`) by default; offer `large-v3` for users wanting maximum accent accuracy. Validate accuracy on the author's accent early in Phase 1. |
| Bundling/integrating `whisper.cpp` in Swift adds complexity. | Well-trodden path on Apple Silicon (Core ML/Metal); optional cloud `gpt-4o-transcribe` can unblock early dev if integration stalls, then swap to local before shipping. |
| Anthropic API key is friction for non-technical users. | Acceptable for the BYOK early-adopter release; the **managed version (Phase 5)** removes it for mass market. |
| Company workspace blocks third-party apps. | Designed around entirely — CrispVoice is not a Slack app and needs no install/approval. |
| Microphone/Accessibility permissions make users nervous. | Clear onboarding explaining *why* each is needed + the no-backend privacy story; notarized/signed build (Phase 4) to maximize trust. |

## 12. Explicitly out of scope for v1 (YAGNI)

- Cloud STT in the shipped product (local `whisper.cpp` only; cloud is dev-only scaffolding).
- A fully-offline rewrite mode (local LLM instead of Claude).
- Posting via the Slack API, OAuth, slash commands, message actions, ephemeral messages.
- A Slack Marketplace listing or any Slack-native app.
- A developer backend, user accounts, billing, or subscriptions.
- Reading the *incoming* message for context-aware replies (possible later via Accessibility; not v1).
- Working in apps other than Slack (the architecture allows it for free, but v1 stays focused on Slack).
- Windows/Linux support.

## 13. Success criteria for the MVP (Phases 0–3)

- From any Slack thread/DM/channel in the **company workspace**, the author can press one hotkey, dictate, pick a crisp version, and send it **as themselves** in under ~10 seconds, without leaving the conversation or touching an admin.
- Transcription handles the author's accent accurately enough that the crisp output reliably reflects intent.
- The crisp output is consistently more concise and clearer than the raw dictation.
- **Privacy holds:** audio and transcripts never leave the device; the only outbound network call is the user's own Claude request; no developer backend is contacted at any point.
- No Slack app is installed anywhere; no API key is hardcoded by the time Phase 3 ships.
