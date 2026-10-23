# CrispVoice

**Read it there. Say your response. Send it there.**

CrispVoice is a native macOS productivity app that brings AI-assisted message formatting directly into the application you are already using.

Read a message in Slack, Microsoft Outlook, Mail, Teams, or another application. Press a global hotkey, speak your response naturally, and choose a polished version. CrispVoice inserts it back into the same application, ready for you to review and send.

No separate drafting window. No platform-specific integration. No switching away from the conversation.

**Default hotkey:** Press `Control + Option + C` to start CrispVoice dictation, then press the same hotkey again to stop recording and generate message variants.

## The Problem

AI assistants such as Claude and Codex can connect to communication tools through APIs and MCP integrations. These workflows can retrieve messages, summarize conversations, and help draft responses.

But they are not always the fastest way to handle a message.

The native application often provides the most useful context: images, attachments, formatting, earlier messages, reactions, participants, and the visual position of the conversation. When you already understand that context and need to respond quickly, opening another AI tool, asking it to retrieve the conversation, drafting a response there, and returning to the original application adds unnecessary friction.

Traditional dictation does not fully solve the problem either. It converts speech into text, but the result often contains filler words, repetition, incomplete sentences, and poorly organized ideas. You still have to rewrite it before sending.

The missing workflow is simple:

> See the complete context in the application where the conversation is happening, speak your response there, and receive an AI-formatted message there.

## The Solution

CrispVoice is designed for these quick-turnaround moments.

It does not need to retrieve or recreate the surrounding conversation. You read the message and absorb its context in the native application. CrispVoice then helps you express your response clearly without moving you into a separate drafting environment.

1. Place your cursor in the application where you want to respond.
2. Press `Control + Option + C` to start CrispVoice.
3. Speak your response naturally.
4. Press `Control + Option + C` again to stop recording.
5. CrispVoice converts your dictation into structured message variants.
6. Choose a Direct, Warmer, or Formal version.
7. The selected message is pasted back into the application where you started.
8. Review it and press Send yourself.

CrispVoice shortens the distance between understanding a message and responding to it.

## Why "CrispVoice"?

Because the goal is not to capture every hesitation exactly as it was spoken.

The goal is to turn your intent into communication that is **clear, concise, and ready to send**.

## More Than Speech-to-Text

CrispVoice is a **voice-to-structured-message conversion system**.

Ordinary dictation tries to reproduce exactly what you said. CrispVoice focuses on communicating what you meant.

```text
You read the conversation in its native application
                         |
                         v
              You speak your response
                         |
                         v
         On-device live transcription
                         |
                         v
     AI-assisted structure and formatting
                         |
                         v
       Direct | Warmer | Formal variants
                         |
                         v
 Message returns to the application where you started
```

It removes filler words, improves sentence structure, adds punctuation, and formats the response for professional communication while preserving your intent.

## Works Where You Work

CrispVoice is application-independent. It works through the macOS interface rather than relying on platform-specific bots, plugins, APIs, or MCP integrations.

It can be used in paste-compatible applications such as:

- Microsoft Outlook
- Slack
- Apple Mail
- Gmail and other browser-based email clients
- Microsoft Teams
- Notion
- Project-management tools
- Customer-support applications
- Any macOS application with a standard text field

CrispVoice does not need permission to access your Slack workspace, Microsoft account, inbox, or conversation history. It formats the response you dictate and returns it to the application already in front of you.

## Built for Quick Turnarounds

CrispVoice is useful when:

- You already understand the conversation and want to respond immediately.
- The native application contains visual context that would be inconvenient to reproduce elsewhere.
- Images, attachments, reactions, or earlier messages influence your response.
- Opening a separate AI assistant would take longer than writing the reply.
- You know what you want to say but want help making it concise and professional.
- Typing and manually editing the message would interrupt your flow.

The objective is not to replace Claude, Codex, or MCP-based assistants. Those tools are valuable for research, retrieval, summarization, and more involved work.

CrispVoice handles a different moment: **you already have the context, and you need to communicate clearly right now.**

## Features

- Global voice capture from anywhere on macOS
- Live transcription using on-device Apple Speech
- Structured rewrites powered by Claude
- Multiple message variants for different ways to express the same intent
- Direct, Warmer, and Formal tone controls
- Application-independent delivery through the macOS clipboard
- Bring your own Anthropic API key, or connect through Amazon Bedrock using your organization's AWS identity
- Anthropic API key storage in macOS Keychain; Amazon Bedrock uses your existing AWS profile and stores no AWS credentials
- No platform-specific bots, plugins, OAuth flows, or developer server
- User-controlled sending so nothing is posted automatically

## Privacy

CrispVoice has no developer-operated backend.

- Audio is processed on your Mac and never uploaded.
- Speech recognition requires on-device Apple Speech support.
- Dictated text is sent directly from your Mac only when it is rewritten, to the rewrite provider you selected in Settings — never to CrispVoice's developer.
  - **Anthropic API** — the request goes directly to `api.anthropic.com` using your own Anthropic API key, stored in macOS Keychain.
  - **Amazon Bedrock** — the request goes directly to the configured AWS Bedrock Runtime endpoint using your AWS identity. Resolving that identity may contact AWS SSO/OIDC/STS endpoints or invoke your administrator-configured local `credential_process`; CrispVoice never stores AWS credentials.
- CrispVoice does not proxy, store, or receive your messages.
- No Slack, Microsoft, or email account access is required.

The only content-bearing network request is the rewrite request sent directly to your selected provider. See [docs/privacy.md](docs/privacy.md) for the full data-flow, IAM, and cross-Region details, and [docs/troubleshooting.md](docs/troubleshooting.md) if a provider fails to connect.

## Architecture

```text
Global hotkey (`Control + Option + C`)
      |
      v
Microphone capture
      |
      v
Apple Speech
(on-device transcription)
      |
      v
Selected rewrite provider
(Anthropic Messages API, or Amazon Bedrock Converse)
      |
      v
Message variants and tone controls
      |
      v
Clipboard + synthesized Command-V
      |
      v
Focused macOS application
```

CrispVoice is built as a native, non-sandboxed macOS menu-bar application using Swift, AppKit, and SwiftUI.

The app intentionally does not use the Mac App Store sandbox because Accessibility permission is required to paste into other applications.

## Installation

Users can install or upgrade CrispVoice from Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/PrachiBhopatkar/CrispVoice/main/scripts/install.sh | /bin/bash
```

This command downloads the latest public GitHub Release, verifies its checksum, universal architecture, bundle identity, and pinned CrispVoice self-signed certificate, then installs it at `~/Applications/CrispVoice.app` without `sudo`. The installer explains that the app is not Apple-notarized and removes quarantine only from the installed CrispVoice app.

After installation:

1. Grant Microphone, Speech Recognition, and Accessibility permissions.
2. In CrispVoice Settings, choose a rewrite provider:
   - **Anthropic API** — add your Anthropic API key. It is stored in macOS Keychain.
   - **Amazon Bedrock** — enter your AWS profile (leave blank to use `default`), AWS Region, and a model or inference-profile identifier. The `Claude Opus 4.8 (US)` preset resolves to the exact model ID `us.anthropic.claude-opus-4-8`; choose `Custom…` to enter another AWS-supported Claude model ID, inference-profile ID, or inference-profile ARN. CrispVoice authenticates using your existing AWS profile and never asks for an AWS access key ID, secret access key, session token, account ID, or user/identity ARN.
3. Place the cursor in the application where you want to write.
4. Press `Control + Option + C` to begin dictating.
5. Press the hotkey again to stop and generate message variants.

If Amazon Bedrock Test Connection fails, see [docs/troubleshooting.md](docs/troubleshooting.md).

## Project Status

CrispVoice is currently a macOS MVP. The core workflow includes global hotkey recording, live on-device transcription, Claude-powered rewriting, message variants, tone controls, secure API-key storage, permission guidance, and paste-back into the previously focused application.

The current release is `v0.3.0`.

## Requirements

- macOS 13 or later
- A Mac and locale that support on-device Apple Speech recognition
- Either an Anthropic API key, or an AWS profile with access to a Claude model on Amazon Bedrock
- Microphone, Speech Recognition, and Accessibility permissions

## Development

The following instructions are for contributors building or testing CrispVoice from source.

### Prerequisites

- Xcode 15 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

### Build

CrispVoice links the Amazon Bedrock SDK as a prebuilt static library rather
than as a native Xcode SPM dependency (Xcode's SPM plugin support has a
build-system regression with `aws-sdk-swift`'s codegen plugin). Before running
`xcodegen generate` for the first time, and again whenever
`vendor/BedrockSDKBridge/Package.swift`'s pinned `aws-sdk-swift` version
changes **and after any Xcode or Swift toolchain upgrade** (the prebuilt
`.swiftmodule` is coupled to the compiler version that produced it, not just
the pinned SDK version), build the vendored library:

```bash
./scripts/build-bedrock-sdk-bridge.sh
```

This produces `vendor/lib/libBedrockSDKBridge.a` and
`vendor/lib/BedrockSDKBridge.swiftmodule/`, which `project.yml` links into the
`CrispVoice` and `CrispVoiceTests` targets via linker settings. These are
build artifacts (gitignored) and must be regenerated locally.

```bash
brew install xcodegen
xcodegen generate

xcodebuild \
  -project CrispVoice.xcodeproj \
  -scheme CrispVoice \
  -configuration Debug \
  build
```

The included helper builds and launches a stable development copy:

```bash
./scripts/run-dev.sh
```

This is the supported development launch path. It signs and opens DevBuild/CrispVoice.app so macOS can preserve Accessibility permission across rebuilds; direct Xcode Run is not covered by this workflow.

### Test

```bash
xcodegen generate

xcodebuild \
  -project CrispVoice.xcodeproj \
  -scheme CrispVoice \
  -destination 'platform=macOS' \
  test
```

## Design Principles

- Voice should produce usable writing, not just a raw transcript.
- The workflow should work across applications.
- Users should not need administrator approval or workspace integrations.
- Audio processing should remain on-device.
- The developer should never receive user content or API keys.
- The user should always review and send the final message.

For more detail, see the [design specification](docs/superpowers/specs/2026-06-12-crispvoice-design.md) and the [Amazon Bedrock provider design](docs/superpowers/specs/2026-08-09-amazon-bedrock-provider-design.md). For data-flow and destination details, see [docs/privacy.md](docs/privacy.md). For setup and connection problems, see [docs/troubleshooting.md](docs/troubleshooting.md).
