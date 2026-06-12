# CrispVoice

A macOS menu-bar companion that turns rough, dictated speech into a crisp, concise Slack message you send **as yourself** — in any workspace, with **no Slack app install**, **no admin approval**, and **no developer backend**. Your audio and transcripts never leave your Mac.

- **On-device transcription** via [`whisper.cpp`](https://github.com/ggerganov/whisper.cpp) (accent-robust, fully offline).
- **Crisp rewrite** by your own Claude (bring your own Anthropic API key).
- **Posts as you** by dropping the polished text into Slack's compose box — you press Enter.

## Status

Early development. See the design spec for the full architecture, privacy model, and phased build plan:

[`docs/superpowers/specs/2026-06-12-crispvoice-design.md`](docs/superpowers/specs/2026-06-12-crispvoice-design.md)

## Privacy

CrispVoice has no servers. Your audio and transcripts stay on your machine. The only outbound network call is the rewrite request you choose to send to Anthropic, authenticated with your own API key.
