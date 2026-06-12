# CrispVoice MVP (Phases 0–3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS menu-bar app that, on a global hotkey, records the mic, transcribes it on-device with whisper.cpp, rewrites it into a crisp message via the user's own Claude, and pastes the result into the focused Slack compose box — with no Slack app, no backend, and no content ever leaving the machine except the user's own Claude call.

**Architecture:** A non-sandboxed AppKit/SwiftUI accessory app (`LSUIElement`). A global hotkey starts/stops a mic recording (`AVAudioEngine`). Audio is converted to 16 kHz mono `[Float]` and transcribed locally by `whisper.cpp` (via the SwiftWhisper package). The transcript is sent to the Anthropic Messages API with the user's own key; the JSON response is parsed into crisp variants shown in a non-activating floating panel. Selecting a variant writes it to the clipboard and synthesizes ⌘V into the still-frontmost Slack window. Pure logic (prompt building, response parsing, audio conversion, clipboard, keychain, preferences) is unit-tested with XCTest; system/UI integration is verified with explicit manual steps.

**Tech Stack:**
- **Language/UI:** Swift 5.9+, AppKit + SwiftUI, macOS 13+ deployment target.
- **Project generation:** XcodeGen (`project.yml` → `.xcodeproj`), built/tested with `xcodebuild`. Keeps everything text-based and agent-editable.
- **Transcription:** [SwiftWhisper](https://github.com/exPHAT/SwiftWhisper) (wraps whisper.cpp). Model: ggml `base` for dev, upgradeable to `small`/`medium`/`large-v3`.
- **Global hotkey:** [HotKey](https://github.com/soffes/HotKey).
- **LLM:** Anthropic Messages API via `URLSession` (no SDK). Default model `claude-haiku-4-5-20251001` (fast/cheap for short rewrites), configurable.
- **Audio:** AVFoundation (`AVAudioEngine`, `AVAudioConverter`).

**Prerequisites (developer machine):**
- macOS 13+ on Apple Silicon, Xcode 15+ installed (`xcodebuild -version` works).
- Homebrew installed.
- An Anthropic API key for end-to-end testing (Phases 1+). Exported as `ANTHROPIC_API_KEY` in the shell during dev; hardcoded reference only until Phase 3 replaces it with Keychain.

**Non-sandbox note:** The app is **not** App-Sandboxed (required for Accessibility keystroke synthesis + direct distribution). Do not enable the App Sandbox capability.

**Permissions used:** Microphone (`NSMicrophoneUsageDescription`, runtime TCC prompt) and Accessibility (runtime TCC grant in System Settings → Privacy & Security → Accessibility; required to post ⌘V to other apps).

---

## File Structure

```
CrispVoice/
├── project.yml                              # XcodeGen project definition
├── scripts/
│   └── download-model.sh                     # fetches a ggml whisper model
├── Models/                                    # (gitignored) downloaded *.bin live here
├── Sources/CrispVoice/
│   ├── App/
│   │   ├── main.swift                         # @main entry, NSApplication bootstrap
│   │   ├── AppDelegate.swift                  # status item + lifecycle + wiring
│   │   └── Info.plist                         # LSUIElement, mic usage string, bundle id
│   ├── Hotkey/HotkeyManager.swift             # global hotkey registration
│   ├── Insert/
│   │   ├── Pasteboard.swift                   # save/restore/set clipboard  [unit-tested]
│   │   └── Inserter.swift                     # set clipboard + synth ⌘V
│   ├── Capture/
│   │   ├── AudioConverter.swift               # → 16 kHz mono [Float]      [unit-tested]
│   │   └── AudioRecorder.swift                # AVAudioEngine mic capture
│   ├── Transcription/Transcriber.swift        # SwiftWhisper wrapper
│   ├── Crisp/
│   │   ├── CrispPrompt.swift                  # builds system+user prompt  [unit-tested]
│   │   ├── CrispResult.swift                  # variants model + parsing   [unit-tested]
│   │   ├── AnthropicClient.swift              # Messages API POST          [unit-tested]
│   │   └── CrispEngine.swift                  # orchestrates the above     [unit-tested]
│   ├── UI/
│   │   ├── CapturePanel.swift                 # non-activating NSPanel host
│   │   └── SuggestionView.swift              # SwiftUI variants + tone buttons
│   ├── Settings/
│   │   ├── KeychainStore.swift               # API key in Keychain        [unit-tested]
│   │   ├── Preferences.swift                 # hotkey/model/tone prefs     [unit-tested]
│   │   └── SettingsView.swift                # SwiftUI settings window
│   └── Onboarding/PermissionsManager.swift   # check/request Accessibility + Mic
└── Tests/CrispVoiceTests/
    ├── PasteboardTests.swift
    ├── AudioConverterTests.swift
    ├── CrispPromptTests.swift
    ├── CrispResultTests.swift
    ├── AnthropicClientTests.swift            # URLProtocol mock
    ├── CrispEngineTests.swift
    ├── KeychainStoreTests.swift
    ├── PreferencesTests.swift
    └── Support/MockURLProtocol.swift
```

**Phase gates:** Phase 0 ends when a hotkey reliably pastes fixed text into Slack. Phase 1 ends when the full dictate→transcribe→crisp→paste loop works with a hardcoded key. Phase 2 ends when variants/tone/edit work in the floating panel. Phase 3 ends when the key lives in Keychain, permissions are guided, and the model is selectable — the shippable personal MVP.

---

# PHASE 0 — De-risk spike: hotkey → paste into Slack

## Task 0.1: Project scaffold + menu-bar app that launches

**Files:**
- Create: `project.yml`
- Create: `Sources/CrispVoice/App/main.swift`
- Create: `Sources/CrispVoice/App/AppDelegate.swift`
- Create: `Sources/CrispVoice/App/Info.plist`

- [ ] **Step 1: Install XcodeGen**

Run: `brew install xcodegen`
Expected: `xcodegen --version` prints a version (e.g., `2.x`).

- [ ] **Step 2: Create `project.yml`**

```yaml
name: CrispVoice
options:
  bundleIdPrefix: com.crispvoice
  deploymentTarget:
    macOS: "13.0"
  createIntermediateGroups: true
packages:
  HotKey:
    url: https://github.com/soffes/HotKey
    from: "0.2.0"
  SwiftWhisper:
    url: https://github.com/exPHAT/SwiftWhisper
    branch: master
targets:
  CrispVoice:
    type: application
    platform: macOS
    sources:
      - path: Sources/CrispVoice
    info:
      path: Sources/CrispVoice/App/Info.plist
      properties:
        LSUIElement: true
        CFBundleName: CrispVoice
        CFBundleShortVersionString: "0.1.0"
        NSMicrophoneUsageDescription: "CrispVoice records your voice locally to transcribe it on your Mac. Audio never leaves your device."
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.crispvoice.app
        MARKETING_VERSION: "0.1.0"
        ENABLE_HARDENED_RUNTIME: YES
        CODE_SIGN_ENTITLEMENTS: ""
        SWIFT_VERSION: "5.9"
    dependencies:
      - package: HotKey
      - package: SwiftWhisper
  CrispVoiceTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: Tests/CrispVoiceTests
    dependencies:
      - target: CrispVoice
schemes:
  CrispVoice:
    build:
      targets:
        CrispVoice: all
        CrispVoiceTests: [test]
    test:
      targets:
        - CrispVoiceTests
```

- [ ] **Step 3: Create `Sources/CrispVoice/App/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>LSUIElement</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>CrispVoice records your voice locally to transcribe it on your Mac. Audio never leaves your device.</string>
</dict>
</plist>
```

- [ ] **Step 4: Create `Sources/CrispVoice/App/AppDelegate.swift`**

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎙️"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "CrispVoice", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }
}
```

- [ ] **Step 5: Create `Sources/CrispVoice/App/main.swift`**

```swift
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
```

- [ ] **Step 6: Generate project and build**

Run:
```bash
xcodegen generate
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Manual verification — app launches as a menu-bar item**

Run:
```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData -name CrispVoice.app -path '*Debug*' | head -1)
open "$APP"
```
Expected: a 🎙️ icon appears in the macOS menu bar, no Dock icon, and clicking it shows a menu with "Quit". Quit it afterward.

- [ ] **Step 8: Commit**

```bash
git add project.yml Sources/CrispVoice/App
echo "CrispVoice.xcodeproj/" >> .gitignore
echo "Models/" >> .gitignore   # already present; harmless if duplicated
git add .gitignore
git commit -m "feat: scaffold CrispVoice menu-bar app (Phase 0.1)"
```

---

## Task 0.2: Pasteboard save/restore/set utility

**Files:**
- Create: `Sources/CrispVoice/Insert/Pasteboard.swift`
- Test: `Tests/CrispVoiceTests/PasteboardTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import CrispVoice

final class PasteboardTests: XCTestCase {
    func test_setString_thenReadString_returnsSameValue() {
        let pb = Pasteboard()
        pb.setString("hello crisp")
        XCTAssertEqual(pb.string(), "hello crisp")
    }

    func test_withTemporaryString_restoresPreviousContents() {
        let pb = Pasteboard()
        pb.setString("original")
        pb.withTemporaryString("temp") {
            XCTAssertEqual(pb.string(), "temp")
        }
        XCTAssertEqual(pb.string(), "original")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test`
Expected: FAIL — `cannot find 'Pasteboard' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import AppKit

/// Thin wrapper over NSPasteboard with save/restore so we never clobber
/// the user's clipboard permanently when pasting.
final class Pasteboard {
    private let pb: NSPasteboard
    init(_ pb: NSPasteboard = .general) { self.pb = pb }

    func string() -> String? {
        pb.string(forType: .string)
    }

    func setString(_ value: String) {
        pb.clearContents()
        pb.setString(value, forType: .string)
    }

    /// Sets `value`, runs `body` (e.g. paste), then restores prior string contents.
    func withTemporaryString(_ value: String, _ body: () -> Void) {
        let previous = pb.string(forType: .string)
        setString(value)
        body()
        if let previous { setString(previous) } else { pb.clearContents() }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test`
Expected: PASS (both PasteboardTests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CrispVoice/Insert/Pasteboard.swift Tests/CrispVoiceTests/PasteboardTests.swift
git commit -m "feat: add Pasteboard with save/restore (Phase 0.2)"
```

---

## Task 0.3: Keystroke synthesizer + Inserter

**Files:**
- Create: `Sources/CrispVoice/Insert/Inserter.swift`

> Synthesizing keystrokes can't be meaningfully unit-tested (it requires the Accessibility TCC grant and a live frontmost app), so this task is verified manually.

- [ ] **Step 1: Write the implementation**

```swift
import AppKit
import CoreGraphics

/// Inserts text into whatever app is frontmost by placing it on the clipboard
/// and synthesizing ⌘V, then restoring the prior clipboard contents.
/// Requires Accessibility permission to post events to other apps.
final class Inserter {
    private let pasteboard: Pasteboard
    init(pasteboard: Pasteboard = Pasteboard()) { self.pasteboard = pasteboard }

    private let vKeyCode: CGKeyCode = 0x09 // "v"

    func insert(_ text: String) {
        pasteboard.withTemporaryString(text) {
            synthesizeCommandV()
            // Give the frontmost app a beat to read the pasteboard before restore.
            usleep(120_000)
        }
    }

    private func synthesizeCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Sources/CrispVoice/Insert/Inserter.swift
git commit -m "feat: add Inserter (clipboard + synth Cmd+V) (Phase 0.3)"
```

---

## Task 0.4: Global hotkey → paste into Slack (THE Phase 0 spike)

**Files:**
- Create: `Sources/CrispVoice/Hotkey/HotkeyManager.swift`
- Modify: `Sources/CrispVoice/App/AppDelegate.swift`

- [ ] **Step 1: Create `HotkeyManager.swift`**

```swift
import HotKey
import AppKit

/// Registers a single global hotkey and invokes a closure on key-down.
final class HotkeyManager {
    private var hotKey: HotKey?

    /// Default: ⌥⌘Space.
    func register(key: Key = .space, modifiers: NSEvent.ModifierFlags = [.command, .option], onTrigger: @escaping () -> Void) {
        let hk = HotKey(key: key, modifiers: modifiers)
        hk.keyDownHandler = onTrigger
        self.hotKey = hk
    }
}
```

- [ ] **Step 2: Wire it in `AppDelegate.swift`** (replace the file's contents)

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let hotkeys = HotkeyManager()
    private let inserter = Inserter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎙️"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "CrispVoice", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        hotkeys.register { [weak self] in
            self?.inserter.insert("CrispVoice spike: this text was pasted by the hotkey.")
        }
    }
}
```

- [ ] **Step 3: Rebuild and launch**

Run:
```bash
xcodegen generate
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -configuration Debug build
APP=$(find ~/Library/Developer/Xcode/DerivedData -name CrispVoice.app -path '*Debug*' | head -1)
open "$APP"
```
Expected: `** BUILD SUCCEEDED **` and the menu-bar icon appears.

- [ ] **Step 4: Grant Accessibility permission**

Open System Settings → Privacy & Security → Accessibility, enable **CrispVoice** (or add the built `.app`). If it's not listed, trigger the hotkey once; macOS will offer to open the pane. Re-launch the app after granting.

- [ ] **Step 5: Manual verification — the spike (paste into Slack)**

1. Open the **Slack desktop app**, click into a channel's compose box (do NOT send).
2. Press **⌥⌘Space**.
3. Expected: the text *"CrispVoice spike: this text was pasted by the hotkey."* appears in the Slack compose box, and your previous clipboard contents are restored (paste elsewhere to confirm).
4. Repeat in a DM and a thread reply box to confirm it works across surfaces.

**This is the Phase 0 gate.** If paste does not land in Slack: confirm Slack is frontmost when the hotkey fires (the panel doesn't exist yet, so Slack should already be frontmost), confirm Accessibility is granted, and try increasing the `usleep` in `Inserter`. Do not proceed until this works.

- [ ] **Step 6: Commit**

```bash
git add Sources/CrispVoice/Hotkey/HotkeyManager.swift Sources/CrispVoice/App/AppDelegate.swift
git commit -m "feat: global hotkey pastes into Slack — Phase 0 spike passes (Phase 0.4)"
```

---

# PHASE 1 — Core loop: dictate → transcribe → crisp → paste

## Task 1.1: AudioConverter (→ 16 kHz mono [Float])

**Files:**
- Create: `Sources/CrispVoice/Capture/AudioConverter.swift`
- Test: `Tests/CrispVoiceTests/AudioConverterTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import AVFoundation
@testable import CrispVoice

final class AudioConverterTests: XCTestCase {
    func test_convert_producesMono16kFloats_fromStereo48kBuffer() throws {
        // 1 second of 48kHz stereo silence.
        let inFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let frames = AVAudioFrameCount(48_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames)!
        buffer.frameLength = frames

        let converter = AudioConverter()
        let out = try converter.toWhisperFrames(buffer)

        // 16kHz mono for 1s ≈ 16000 samples (allow small resampler delta).
        XCTAssertGreaterThan(out.count, 15_000)
        XCTAssertLessThan(out.count, 17_000)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test`
Expected: FAIL — `cannot find 'AudioConverter' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import AVFoundation

/// Converts captured PCM buffers to the format whisper.cpp expects:
/// 16 kHz, mono, 32-bit float, non-interleaved.
struct AudioConverter {
    enum ConvertError: Error { case formatUnavailable, conversionFailed }

    func toWhisperFrames(_ input: AVAudioPCMBuffer) throws -> [Float] {
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else { throw ConvertError.formatUnavailable }

        guard let converter = AVAudioConverter(from: input.format, to: outFormat) else {
            throw ConvertError.conversionFailed
        }

        let ratio = outFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
            throw ConvertError.conversionFailed
        }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }

        guard let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrispVoice/Capture/AudioConverter.swift Tests/CrispVoiceTests/AudioConverterTests.swift
git commit -m "feat: add AudioConverter to 16kHz mono floats (Phase 1.1)"
```

---

## Task 1.2: AudioRecorder (mic capture)

**Files:**
- Create: `Sources/CrispVoice/Capture/AudioRecorder.swift`

> Live mic capture is verified manually (TCC + hardware).

- [ ] **Step 1: Write the implementation**

```swift
import AVFoundation

/// Captures microphone audio while recording, then returns whisper-ready frames.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private let converter = AudioConverter()
    private var collected: [Float] = []
    private(set) var isRecording = false

    func start() throws {
        collected.removeAll()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            if let frames = try? self.converter.toWhisperFrames(buffer) {
                self.collected.append(contentsOf: frames)
            }
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stops capture and returns the full 16 kHz mono float buffer.
    func stop() -> [Float] {
        guard isRecording else { return collected }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        return collected
    }
}
```

- [ ] **Step 2: Add a temporary debug hook in `AppDelegate`** to verify capture. In `applicationDidFinishLaunching`, replace the hotkey registration body with a toggle:

```swift
        let recorder = AudioRecorder()
        self.debugRecorder = recorder
        hotkeys.register { [weak self] in
            guard let self else { return }
            if recorder.isRecording {
                let frames = recorder.stop()
                NSLog("CrispVoice: captured \(frames.count) frames")
            } else {
                try? recorder.start()
                NSLog("CrispVoice: recording…")
            }
        }
```

Add the stored property near the top of the class: `private var debugRecorder: AudioRecorder?`

- [ ] **Step 3: Build, launch, grant Microphone permission**

Run: `xcodegen generate && xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -configuration Debug build`
Then `open` the app, press the hotkey (macOS prompts for Microphone — allow), speak ~3 seconds, press the hotkey again.

- [ ] **Step 4: Manual verification — frames captured**

Run: `log stream --predicate 'eventMessage CONTAINS "CrispVoice"' --info` in a terminal while toggling.
Expected: a `recording…` line, then `captured N frames` where N ≈ 16000 × seconds spoken (e.g., ~48000 for 3s).

- [ ] **Step 5: Commit**

```bash
git add Sources/CrispVoice/Capture/AudioRecorder.swift Sources/CrispVoice/App/AppDelegate.swift
git commit -m "feat: add AudioRecorder mic capture (Phase 1.2)"
```

---

## Task 1.3: Transcriber (SwiftWhisper) + model download

**Files:**
- Create: `scripts/download-model.sh`
- Create: `Sources/CrispVoice/Transcription/Transcriber.swift`

- [ ] **Step 1: Create `scripts/download-model.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
MODEL="${1:-base}"   # base | small | medium | large-v3
DEST="Models"
mkdir -p "$DEST"
URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${MODEL}.bin"
echo "Downloading ggml-${MODEL}.bin …"
curl -L --fail -o "${DEST}/ggml-${MODEL}.bin" "$URL"
echo "Saved to ${DEST}/ggml-${MODEL}.bin"
```

- [ ] **Step 2: Download the dev model**

Run:
```bash
chmod +x scripts/download-model.sh
./scripts/download-model.sh base
ls -lh Models/ggml-base.bin
```
Expected: a ~142 MB `Models/ggml-base.bin`. (It's gitignored via `*.bin`.)

- [ ] **Step 3: Write `Transcriber.swift`**

```swift
import Foundation
import SwiftWhisper

/// Wraps whisper.cpp (via SwiftWhisper) for on-device transcription.
final class Transcriber {
    private let whisper: Whisper

    init(modelURL: URL) {
        self.whisper = Whisper(fromFileURL: modelURL)
    }

    /// Transcribes 16 kHz mono float frames into a single trimmed string.
    func transcribe(_ frames: [Float]) async throws -> String {
        let segments = try await whisper.transcribe(audioFrames: frames)
        return segments.map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 4: Add a debug transcription path in `AppDelegate`** — after `recorder.stop()` in the hotkey toggle, transcribe and log:

```swift
                let frames = recorder.stop()
                let modelURL = Bundle.main.url(forResource: "ggml-base", withExtension: "bin")
                    ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/Models/ggml-base.bin")
                let transcriber = Transcriber(modelURL: modelURL)
                Task {
                    let text = (try? await transcriber.transcribe(frames)) ?? "<failed>"
                    NSLog("CrispVoice transcript: \(text)")
                }
```

> For now the model is read from the repo's `Models/` dir at the dev working directory. Bundling into the `.app` Resources is handled in Phase 3 (Task 3.6 note) / Phase 4.

- [ ] **Step 5: Build and manually verify transcription**

Run from the repo root so the relative `Models/` path resolves:
```bash
xcodegen generate && xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -configuration Debug build
APP=$(find ~/Library/Developer/Xcode/DerivedData -name CrispVoice.app -path '*Debug*' | head -1)
( cd "$(pwd)"; open "$APP" )
log stream --predicate 'eventMessage CONTAINS "CrispVoice transcript"' --info
```
Toggle the hotkey, speak a clear sentence, toggle again.
Expected: a `CrispVoice transcript: <your sentence>` log line that roughly matches what you said.

- [ ] **Step 6: Commit**

```bash
git add scripts/download-model.sh Sources/CrispVoice/Transcription/Transcriber.swift Sources/CrispVoice/App/AppDelegate.swift
git commit -m "feat: add on-device Transcriber via SwiftWhisper (Phase 1.3)"
```

---

## Task 1.4: CrispPrompt (system + user prompt builder)

**Files:**
- Create: `Sources/CrispVoice/Crisp/CrispPrompt.swift`
- Test: `Tests/CrispVoiceTests/CrispPromptTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import CrispVoice

final class CrispPromptTests: XCTestCase {
    func test_system_requestsJSONVariantsAndCleanup() {
        let s = CrispPrompt.system(variantCount: 3)
        XCTAssertTrue(s.contains("JSON"))
        XCTAssertTrue(s.lowercased().contains("dictation"))
        XCTAssertTrue(s.contains("3"))
    }

    func test_user_embedsRawTranscriptAndTone() {
        let u = CrispPrompt.user(transcript: "hey can u snd me teh deck", tone: .direct)
        XCTAssertTrue(u.contains("hey can u snd me teh deck"))
        XCTAssertTrue(u.lowercased().contains("direct"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test`
Expected: FAIL — `cannot find 'CrispPrompt' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

enum Tone: String, CaseIterable {
    case neutral, shorter, direct, warmer
    var instruction: String {
        switch self {
        case .neutral: return "Keep a natural, professional tone."
        case .shorter: return "Make it as short as possible while keeping the meaning."
        case .direct:  return "Make it direct and to the point."
        case .warmer:  return "Make it warmer and friendlier."
        }
    }
}

enum CrispPrompt {
    static func system(variantCount: Int) -> String {
        """
        You rewrite rough, dictated Slack messages into crisp, clear ones.
        The input is a raw speech-to-text transcript and may contain dictation errors, \
        filler words, and accent-related mistranscriptions — infer the intended meaning and fix them.
        Rewrite it to be concise, well-punctuated, and ready to send in Slack. Do not add greetings \
        or sign-offs that weren't intended. Preserve the user's intent and any concrete details \
        (names, dates, links).
        Return ONLY valid JSON of the form: {"variants": ["...", "..."]} with exactly \(variantCount) \
        distinct variants, best first. No prose outside the JSON.
        """
    }

    static func user(transcript: String, tone: Tone) -> String {
        """
        Tone: \(tone.instruction)

        Raw transcript:
        \"\"\"
        \(transcript)
        \"\"\"
        """
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrispVoice/Crisp/CrispPrompt.swift Tests/CrispVoiceTests/CrispPromptTests.swift
git commit -m "feat: add CrispPrompt builder with tones (Phase 1.4)"
```

---

## Task 1.5: CrispResult (variants model + parsing)

**Files:**
- Create: `Sources/CrispVoice/Crisp/CrispResult.swift`
- Test: `Tests/CrispVoiceTests/CrispResultTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import CrispVoice

final class CrispResultTests: XCTestCase {
    func test_parse_extractsVariantsFromCleanJSON() throws {
        let json = #"{"variants": ["Can you send me the deck?", "Please share the deck."]}"#
        let result = try CrispResult.parse(json)
        XCTAssertEqual(result.variants, ["Can you send me the deck?", "Please share the deck."])
    }

    func test_parse_toleratesSurroundingProseAndCodeFences() throws {
        let messy = "Sure!\n```json\n{\"variants\": [\"Hello there.\"]}\n```\nHope that helps."
        let result = try CrispResult.parse(messy)
        XCTAssertEqual(result.variants, ["Hello there."])
    }

    func test_parse_throwsOnNoJSON() {
        XCTAssertThrowsError(try CrispResult.parse("no json here"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test`
Expected: FAIL — `cannot find 'CrispResult' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

struct CrispResult: Equatable {
    let variants: [String]

    enum ParseError: Error { case noJSONObject, decodeFailed }

    private struct Payload: Decodable { let variants: [String] }

    /// Extracts the first top-level JSON object from `text` (tolerating code
    /// fences / surrounding prose) and decodes its `variants` array.
    static func parse(_ text: String) throws -> CrispResult {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"), start < end else {
            throw ParseError.noJSONObject
        }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw ParseError.decodeFailed
        }
        return CrispResult(variants: payload.variants)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrispVoice/Crisp/CrispResult.swift Tests/CrispVoiceTests/CrispResultTests.swift
git commit -m "feat: add CrispResult JSON parsing (Phase 1.5)"
```

---

## Task 1.6: AnthropicClient (Messages API)

**Files:**
- Create: `Sources/CrispVoice/Crisp/AnthropicClient.swift`
- Create: `Tests/CrispVoiceTests/Support/MockURLProtocol.swift`
- Test: `Tests/CrispVoiceTests/AnthropicClientTests.swift`

- [ ] **Step 1: Create `MockURLProtocol.swift`**

```swift
import Foundation

final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            fatalError("MockURLProtocol.handler not set")
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
```

- [ ] **Step 2: Write the failing test**

```swift
import XCTest
@testable import CrispVoice

final class AnthropicClientTests: XCTestCase {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    func test_complete_sendsKeyAndReturnsAssistantText() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            let body = #"{"content":[{"type":"text","text":"{\"variants\":[\"Hi\"]}"}]}"#
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, body.data(using: .utf8)!)
        }
        let client = AnthropicClient(apiKey: "sk-test", model: "claude-haiku-4-5-20251001", session: makeSession())
        let text = try await client.complete(system: "sys", user: "usr", maxTokens: 64)
        XCTAssertEqual(text, #"{"variants":["Hi"]}"#)
    }

    func test_complete_throwsOnNon200() async {
        MockURLProtocol.handler = { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (resp, Data("unauthorized".utf8))
        }
        let client = AnthropicClient(apiKey: "bad", model: "claude-haiku-4-5-20251001", session: makeSession())
        do { _ = try await client.complete(system: "s", user: "u", maxTokens: 64); XCTFail("expected throw") }
        catch {}
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test`
Expected: FAIL — `cannot find 'AnthropicClient' in scope`.

- [ ] **Step 4: Write minimal implementation**

```swift
import Foundation

/// Minimal Anthropic Messages API client. Called directly from the user's
/// machine with the user's own key — no backend in the path.
final class AnthropicClient {
    enum ClientError: Error { case http(Int, String), badResponse }

    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    init(apiKey: String, model: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    private struct Response: Decodable {
        struct Block: Decodable { let type: String; let text: String? }
        let content: [Block]
    }

    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.badResponse }
        guard http.statusCode == 200 else {
            throw ClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let text = decoded.content.compactMap { $0.text }.joined()
        guard !text.isEmpty else { throw ClientError.badResponse }
        return text
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/CrispVoice/Crisp/AnthropicClient.swift Tests/CrispVoiceTests/Support/MockURLProtocol.swift Tests/CrispVoiceTests/AnthropicClientTests.swift
git commit -m "feat: add AnthropicClient with mocked tests (Phase 1.6)"
```

---

## Task 1.7: CrispEngine (orchestration)

**Files:**
- Create: `Sources/CrispVoice/Crisp/CrispEngine.swift`
- Test: `Tests/CrispVoiceTests/CrispEngineTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import CrispVoice

private struct StubCompleter: TextCompleter {
    let canned: String
    func complete(system: String, user: String) async throws -> String { canned }
}

final class CrispEngineTests: XCTestCase {
    func test_crisp_returnsParsedVariants() async throws {
        let stub = StubCompleter(canned: #"{"variants":["Send the deck please.","Please share the deck."]}"#)
        let engine = CrispEngine(completer: stub, variantCount: 2)
        let result = try await engine.crisp(transcript: "snd me teh deck", tone: .neutral)
        XCTAssertEqual(result.variants.count, 2)
        XCTAssertEqual(result.variants.first, "Send the deck please.")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test`
Expected: FAIL — `cannot find 'CrispEngine' / 'TextCompleter' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Abstraction so CrispEngine can be tested without network.
protocol TextCompleter {
    func complete(system: String, user: String) async throws -> String
}

extension AnthropicClient: TextCompleter {
    func complete(system: String, user: String) async throws -> String {
        try await complete(system: system, user: user, maxTokens: 1024)
    }
}

final class CrispEngine {
    private let completer: TextCompleter
    private let variantCount: Int

    init(completer: TextCompleter, variantCount: Int = 3) {
        self.completer = completer
        self.variantCount = variantCount
    }

    func crisp(transcript: String, tone: Tone) async throws -> CrispResult {
        let system = CrispPrompt.system(variantCount: variantCount)
        let user = CrispPrompt.user(transcript: transcript, tone: tone)
        let raw = try await completer.complete(system: system, user: user)
        return try CrispResult.parse(raw)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrispVoice/Crisp/CrispEngine.swift Tests/CrispVoiceTests/CrispEngineTests.swift
git commit -m "feat: add CrispEngine orchestration (Phase 1.7)"
```

---

## Task 1.8: Wire the full loop (hotkey → record → transcribe → crisp → paste)

**Files:**
- Modify: `Sources/CrispVoice/App/AppDelegate.swift`

> End-to-end manual verification. Uses a hardcoded key from the environment for now (replaced by Keychain in Phase 3).

- [ ] **Step 1: Replace `AppDelegate.swift` with the wired loop**

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let hotkeys = HotkeyManager()
    private let inserter = Inserter()
    private let recorder = AudioRecorder()
    private lazy var transcriber = Transcriber(modelURL: Self.devModelURL())
    private lazy var engine = CrispEngine(
        completer: AnthropicClient(
            apiKey: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "",
            model: "claude-haiku-4-5-20251001"
        ),
        variantCount: 1
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎙️"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        hotkeys.register { [weak self] in self?.toggle() }
    }

    private func toggle() {
        if recorder.isRecording {
            statusItem.button?.title = "⏳"
            let frames = recorder.stop()
            Task { await self.process(frames) }
        } else {
            try? recorder.start()
            statusItem.button?.title = "🔴"
        }
    }

    private func process(_ frames: [Float]) async {
        defer { Task { @MainActor in self.statusItem.button?.title = "🎙️" } }
        do {
            let transcript = try await transcriber.transcribe(frames)
            guard !transcript.isEmpty else { return }
            let result = try await engine.crisp(transcript: transcript, tone: .neutral)
            guard let best = result.variants.first else { return }
            await MainActor.run { self.inserter.insert(best) }
        } catch {
            NSLog("CrispVoice error: \(error)")
        }
    }

    private static func devModelURL() -> URL {
        if let bundled = Bundle.main.url(forResource: "ggml-base", withExtension: "bin") { return bundled }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/Models/ggml-base.bin")
    }
}
```

- [ ] **Step 2: Build and launch with the key in the environment**

Run from the repo root (so `Models/` resolves):
```bash
xcodegen generate && xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -configuration Debug build
APP=$(find ~/Library/Developer/Xcode/DerivedData -name CrispVoice.app -path '*Debug*' | head -1)
ANTHROPIC_API_KEY="<your-key>" open "$APP" --env ANTHROPIC_API_KEY
```
(If `open --env` is unavailable, launch the binary directly: `ANTHROPIC_API_KEY=<key> "$APP/Contents/MacOS/CrispVoice"`.)

- [ ] **Step 3: Manual verification — the full loop**

1. Click into the Slack compose box.
2. Press ⌥⌘Space (icon → 🔴), say *"hey can you send me the latest deck before the three pm sync"*, press ⌥⌘Space again (icon → ⏳ → 🎙️).
3. Expected: within a couple seconds, a crisp version (e.g., *"Can you send me the latest deck before the 3 PM sync?"*) is pasted into the Slack compose box.

**Phase 1 gate:** the loop works end to end. Do not proceed until a spoken sentence reliably becomes a crisp pasted message.

- [ ] **Step 4: Commit**

```bash
git add Sources/CrispVoice/App/AppDelegate.swift
git commit -m "feat: wire full dictate→transcribe→crisp→paste loop (Phase 1.8)"
```

---

# PHASE 2 — Quality & control: variants, tone, panel, edit

## Task 2.1: Non-activating CapturePanel

**Files:**
- Create: `Sources/CrispVoice/UI/CapturePanel.swift`

> A non-activating panel is essential: Slack must stay frontmost so ⌘V lands there.

- [ ] **Step 1: Write the implementation**

```swift
import AppKit
import SwiftUI

/// A floating, non-activating panel that hosts SwiftUI content over the
/// current app WITHOUT stealing key focus from Slack.
final class CapturePanel<Content: View>: NSPanel {
    init(content: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        contentView = NSHostingView(rootView: content)
        positionTopCenter()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func positionTopCenter() {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.maxY - frame.height - 80))
    }

    func present() { orderFrontRegardless() }
    func dismiss() { orderOut(nil) }
}
```

- [ ] **Step 2: Build**

Run: `xcodegen generate && xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Sources/CrispVoice/UI/CapturePanel.swift
git commit -m "feat: add non-activating CapturePanel (Phase 2.1)"
```

---

## Task 2.2: SuggestionView (variants + tone buttons)

**Files:**
- Create: `Sources/CrispVoice/UI/SuggestionView.swift`

- [ ] **Step 1: Write the implementation**

```swift
import SwiftUI

/// View-model driving the suggestion panel. Observable so the panel updates
/// as transcription/crisping progresses.
final class SuggestionModel: ObservableObject {
    @Published var status: String = "Listening…"
    @Published var variants: [String] = []
    @Published var isWorking: Bool = false

    var onPick: (String) -> Void = { _ in }
    var onTone: (Tone) -> Void = { _ in }
    var onRegenerate: () -> Void = {}
}

struct SuggestionView: View {
    @ObservedObject var model: SuggestionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("CrispVoice").font(.headline)
                Spacer()
                if model.isWorking { ProgressView().scaleEffect(0.6) }
            }
            if model.variants.isEmpty {
                Text(model.status).foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.variants.enumerated()), id: \.offset) { _, variant in
                    Button { model.onPick(variant) } label: {
                        Text(variant).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8).background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
                HStack(spacing: 6) {
                    toneButton("Shorter", .shorter)
                    toneButton("Direct", .direct)
                    toneButton("Warmer", .warmer)
                    Button("Regenerate") { model.onRegenerate() }
                }.font(.caption)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func toneButton(_ label: String, _ tone: Tone) -> some View {
        Button(label) { model.onTone(tone) }
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodegen generate && xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Sources/CrispVoice/UI/SuggestionView.swift
git commit -m "feat: add SuggestionView with tone buttons (Phase 2.2)"
```

---

## Task 2.3: Wire panel into the loop with multiple variants + tone/regenerate

**Files:**
- Modify: `Sources/CrispVoice/App/AppDelegate.swift`

- [ ] **Step 1: Replace `AppDelegate.swift`** to drive the panel and keep the last transcript for tone re-runs

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let hotkeys = HotkeyManager()
    private let inserter = Inserter()
    private let recorder = AudioRecorder()
    private lazy var transcriber = Transcriber(modelURL: Self.devModelURL())
    private lazy var engine = CrispEngine(
        completer: AnthropicClient(
            apiKey: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "",
            model: "claude-haiku-4-5-20251001"
        ),
        variantCount: 3
    )

    private let model = SuggestionModel()
    private var panel: CapturePanel<SuggestionView>!
    private var lastTranscript = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎙️"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        panel = CapturePanel(content: SuggestionView(model: model))
        model.onPick = { [weak self] text in self?.send(text) }
        model.onTone = { [weak self] tone in self?.rerun(tone: tone) }
        model.onRegenerate = { [weak self] in self?.rerun(tone: .neutral) }

        hotkeys.register { [weak self] in self?.toggle() }
    }

    private func toggle() {
        if recorder.isRecording {
            statusItem.button?.title = "⏳"
            let frames = recorder.stop()
            model.isWorking = true
            model.status = "Transcribing…"
            Task { await self.transcribeThenCrisp(frames) }
        } else {
            try? recorder.start()
            statusItem.button?.title = "🔴"
            model.variants = []
            model.status = "Listening…"
            panel.present()
        }
    }

    private func transcribeThenCrisp(_ frames: [Float]) async {
        do {
            let transcript = try await transcriber.transcribe(frames)
            lastTranscript = transcript
            await MainActor.run { self.model.status = "Crisping…" }
            await runCrisp(tone: .neutral)
        } catch { await fail(error) }
        await MainActor.run { self.statusItem.button?.title = "🎙️" }
    }

    private func rerun(tone: Tone) {
        guard !lastTranscript.isEmpty else { return }
        model.isWorking = true
        Task { await runCrisp(tone: tone) }
    }

    private func runCrisp(tone: Tone) async {
        do {
            let result = try await engine.crisp(transcript: lastTranscript, tone: tone)
            await MainActor.run {
                self.model.variants = result.variants
                self.model.isWorking = false
            }
        } catch { await fail(error) }
    }

    private func send(_ text: String) {
        panel.dismiss()
        inserter.insert(text)
    }

    private func fail(_ error: Error) async {
        await MainActor.run {
            self.model.isWorking = false
            self.model.status = "Error: \(error.localizedDescription)"
        }
    }

    private static func devModelURL() -> URL {
        if let bundled = Bundle.main.url(forResource: "ggml-base", withExtension: "bin") { return bundled }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/Models/ggml-base.bin")
    }
}
```

- [ ] **Step 2: Build, launch, and manually verify variants + tone**

Run: `xcodegen generate && xcodebuild ... build` then launch with `ANTHROPIC_API_KEY` as in Task 1.8.
1. Click into Slack, hotkey, dictate, hotkey.
2. Expected: the floating panel shows 3 variants; Slack stays frontmost (its compose box keeps its cursor).
3. Click **Shorter** / **Direct** / **Warmer** → variants refresh accordingly. Click **Regenerate** → new set.
4. Click a variant → panel closes and that text pastes into Slack.

- [ ] **Step 3: Commit**

```bash
git add Sources/CrispVoice/App/AppDelegate.swift
git commit -m "feat: drive suggestion panel with variants + tone re-runs (Phase 2.3)"
```

---

## Task 2.4: Inline edit before send

**Files:**
- Modify: `Sources/CrispVoice/UI/SuggestionView.swift`

- [ ] **Step 1: Add an editable field bound to the focused variant.** Add to `SuggestionModel`:

```swift
    @Published var editText: String = ""
```

And in `SuggestionView`, replace the `ForEach(...)` block's button label interaction so a single click loads the variant into an editor, with a Send button:

```swift
                ForEach(Array(model.variants.enumerated()), id: \.offset) { _, variant in
                    Button { model.editText = variant } label: {
                        Text(variant).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8).background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
                if !model.editText.isEmpty {
                    TextEditor(text: $model.editText)
                        .frame(height: 64).border(.secondary)
                    HStack {
                        Spacer()
                        Button("Send") { model.onPick(model.editText) }
                            .keyboardShortcut(.return, modifiers: [.command])
                    }
                }
```

- [ ] **Step 2: Build and manually verify**

Click a variant → it loads into the editor → tweak the text → **Send** (or ⌘↩) pastes the edited text into Slack.

- [ ] **Step 3: Commit**

```bash
git add Sources/CrispVoice/UI/SuggestionView.swift
git commit -m "feat: inline edit before send (Phase 2.4)"
```

---

## Task 2.5: Prompt tuning pass

**Files:**
- Modify: `Sources/CrispVoice/Crisp/CrispPrompt.swift`
- Modify: `Tests/CrispVoiceTests/CrispPromptTests.swift`

- [ ] **Step 1: Add a test pinning the anti-hallucination rule**

```swift
    func test_system_forbidsInventingFacts() {
        let s = CrispPrompt.system(variantCount: 3)
        XCTAssertTrue(s.lowercased().contains("do not invent"))
    }
```

- [ ] **Step 2: Run it to confirm failure**

Run: `xcodebuild ... test`
Expected: FAIL on `test_system_forbidsInventingFacts`.

- [ ] **Step 3: Update the system prompt** — add this sentence before the JSON instruction in `CrispPrompt.system`:

```
Do not invent facts, names, numbers, or commitments that are not present in the transcript.
```

- [ ] **Step 4: Run tests to verify pass**

Run: `xcodebuild ... test`
Expected: PASS (all CrispPromptTests).

- [ ] **Step 5: Manual quality check** — dictate 5 varied messages (a question, a status update, a thank-you, a scheduling note, a decision) and confirm outputs are concise, faithful, and free of invented details. Adjust wording in `CrispPrompt.system` if needed (tests still pass).

- [ ] **Step 6: Commit**

```bash
git add Sources/CrispVoice/Crisp/CrispPrompt.swift Tests/CrispVoiceTests/CrispPromptTests.swift
git commit -m "feat: tune crisp prompt to forbid invented facts (Phase 2.5)"
```

---

# PHASE 3 — Settings & onboarding (shippable personal MVP)

## Task 3.1: KeychainStore

**Files:**
- Create: `Sources/CrispVoice/Settings/KeychainStore.swift`
- Test: `Tests/CrispVoiceTests/KeychainStoreTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import CrispVoice

final class KeychainStoreTests: XCTestCase {
    private let service = "com.crispvoice.tests.\(UUID().uuidString)"

    func test_saveThenRead_returnsValue() throws {
        let store = KeychainStore(service: service)
        try store.set("sk-secret")
        XCTAssertEqual(store.get(), "sk-secret")
    }

    func test_overwrite_updatesValue() throws {
        let store = KeychainStore(service: service)
        try store.set("first")
        try store.set("second")
        XCTAssertEqual(store.get(), "second")
    }

    func test_delete_removesValue() throws {
        let store = KeychainStore(service: service)
        try store.set("gone")
        try store.delete()
        XCTAssertNil(store.get())
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild ... test`
Expected: FAIL — `cannot find 'KeychainStore' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation
import Security

/// Stores the Anthropic API key in the macOS Keychain. The key never leaves
/// the machine except in the user's own Anthropic request.
final class KeychainStore {
    enum KeychainError: Error { case unexpected(OSStatus) }

    private let service: String
    private let account = "anthropic-api-key"

    init(service: String = "com.crispvoice.app") { self.service = service }

    func set(_ value: String) throws {
        try? delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8)
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpected(status) }
    }

    func get() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpected(status)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild ... test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrispVoice/Settings/KeychainStore.swift Tests/CrispVoiceTests/KeychainStoreTests.swift
git commit -m "feat: add KeychainStore for API key (Phase 3.1)"
```

---

## Task 3.2: Preferences (hotkey, model, variant count)

**Files:**
- Create: `Sources/CrispVoice/Settings/Preferences.swift`
- Test: `Tests/CrispVoiceTests/PreferencesTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import CrispVoice

final class PreferencesTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        return d
    }

    func test_defaults_areSensible() {
        let prefs = Preferences(defaults: freshDefaults())
        XCTAssertEqual(prefs.modelName, "claude-haiku-4-5-20251001")
        XCTAssertEqual(prefs.whisperModel, "base")
        XCTAssertEqual(prefs.variantCount, 3)
    }

    func test_setters_persist() {
        let d = freshDefaults()
        let prefs = Preferences(defaults: d)
        prefs.whisperModel = "small"
        prefs.variantCount = 2
        let reloaded = Preferences(defaults: d)
        XCTAssertEqual(reloaded.whisperModel, "small")
        XCTAssertEqual(reloaded.variantCount, 2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild ... test`
Expected: FAIL — `cannot find 'Preferences' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

final class Preferences {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var modelName: String {
        get { defaults.string(forKey: "modelName") ?? "claude-haiku-4-5-20251001" }
        set { defaults.set(newValue, forKey: "modelName") }
    }
    var whisperModel: String {
        get { defaults.string(forKey: "whisperModel") ?? "base" }
        set { defaults.set(newValue, forKey: "whisperModel") }
    }
    var variantCount: Int {
        get { defaults.object(forKey: "variantCount") as? Int ?? 3 }
        set { defaults.set(newValue, forKey: "variantCount") }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild ... test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrispVoice/Settings/Preferences.swift Tests/CrispVoiceTests/PreferencesTests.swift
git commit -m "feat: add Preferences store (Phase 3.2)"
```

---

## Task 3.3: SettingsView (API key + model picker)

**Files:**
- Create: `Sources/CrispVoice/Settings/SettingsView.swift`
- Modify: `Sources/CrispVoice/App/AppDelegate.swift` (add a "Settings…" menu item that opens a window hosting `SettingsView`)

- [ ] **Step 1: Write `SettingsView.swift`**

```swift
import SwiftUI

final class SettingsModel: ObservableObject {
    @Published var apiKey: String = ""
    @Published var whisperModel: String = "base"
    @Published var validationMessage: String = ""

    private let keychain: KeychainStore
    private let prefs: Preferences

    init(keychain: KeychainStore = KeychainStore(), prefs: Preferences = Preferences()) {
        self.keychain = keychain
        self.prefs = prefs
        self.apiKey = keychain.get() ?? ""
        self.whisperModel = prefs.whisperModel
    }

    func save() {
        try? keychain.set(apiKey)
        prefs.whisperModel = whisperModel
    }

    func validate() async {
        do {
            let client = AnthropicClient(apiKey: apiKey, model: prefs.modelName)
            _ = try await client.complete(system: "Reply with OK.", user: "ping", maxTokens: 5)
            await MainActor.run { self.validationMessage = "✅ Key works." }
        } catch {
            await MainActor.run { self.validationMessage = "❌ \(error.localizedDescription)" }
        }
    }
}

struct SettingsView: View {
    @StateObject var model = SettingsModel()
    private let whisperOptions = ["base", "small", "medium", "large-v3"]

    var body: some View {
        Form {
            Section("Anthropic API key") {
                SecureField("sk-ant-…", text: $model.apiKey)
                HStack {
                    Button("Save") { model.save() }
                    Button("Test") { Task { await model.validate() } }
                    Text(model.validationMessage).font(.caption)
                }
            }
            Section("Transcription model") {
                Picker("Whisper model", selection: $model.whisperModel) {
                    ForEach(whisperOptions, id: \.self) { Text($0) }
                }
                Text("Larger models are more accurate on accents but bigger/slower.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onChange(of: model.whisperModel) { _ in model.save() }
    }
}
```

- [ ] **Step 2: Add a Settings window opener in `AppDelegate`.** Add a property and menu item, and a method:

```swift
    private var settingsWindow: NSWindow?
    // In applicationDidFinishLaunching, before the Quit item:
    // menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))

    @objc private func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "CrispVoice Settings"
            window.styleMask = [.titled, .closable]
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
```

Add `import SwiftUI` at the top of `AppDelegate.swift`.

- [ ] **Step 3: Build and manually verify**

Open the menu-bar menu → **Settings…** → enter your key → **Test** → expect "✅ Key works." Pick a whisper model; it persists across relaunch.

- [ ] **Step 4: Commit**

```bash
git add Sources/CrispVoice/Settings/SettingsView.swift Sources/CrispVoice/App/AppDelegate.swift
git commit -m "feat: add Settings window (API key + model picker) (Phase 3.3)"
```

---

## Task 3.4: PermissionsManager + first-run onboarding

**Files:**
- Create: `Sources/CrispVoice/Onboarding/PermissionsManager.swift`
- Modify: `Sources/CrispVoice/App/AppDelegate.swift`

- [ ] **Step 1: Write `PermissionsManager.swift`**

```swift
import AppKit
import AVFoundation

enum PermissionsManager {
    static func hasAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prompts (once) for Accessibility; opens the pane if not yet granted.
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
```

- [ ] **Step 2: Gate the first recording on permissions in `AppDelegate`.** In `applicationDidFinishLaunching`, after building the menu:

```swift
        if !PermissionsManager.hasAccessibility() {
            PermissionsManager.requestAccessibility()
        }
        Task { _ = await PermissionsManager.requestMicrophone() }
```

And in `toggle()`, before `recorder.start()`, guard:

```swift
        guard PermissionsManager.hasAccessibility() else {
            PermissionsManager.openAccessibilitySettings()
            return
        }
```

- [ ] **Step 3: Build and manually verify**

On a machine where CrispVoice lacks Accessibility, launching prompts for it and the hotkey opens the Accessibility pane; Microphone is requested on first launch. After granting both, the loop works.

- [ ] **Step 4: Commit**

```bash
git add Sources/CrispVoice/Onboarding/PermissionsManager.swift Sources/CrispVoice/App/AppDelegate.swift
git commit -m "feat: add permissions gating + onboarding prompts (Phase 3.4)"
```

---

## Task 3.5: Replace hardcoded key + wire model selection (MVP gate)

**Files:**
- Modify: `Sources/CrispVoice/App/AppDelegate.swift`

- [ ] **Step 1: Build the engine/transcriber from Keychain + Preferences instead of env/hardcode.** Replace the `engine`/`transcriber` lazy initializers and add a rebuild method:

```swift
    private let keychain = KeychainStore()
    private let prefs = Preferences()
    private var engine: CrispEngine!
    private var transcriber: Transcriber!

    private func rebuildPipeline() {
        let key = keychain.get() ?? ""
        engine = CrispEngine(
            completer: AnthropicClient(apiKey: key, model: prefs.modelName),
            variantCount: prefs.variantCount
        )
        transcriber = Transcriber(modelURL: Self.modelURL(for: prefs.whisperModel))
    }

    private static func modelURL(for name: String) -> URL {
        if let bundled = Bundle.main.url(forResource: "ggml-\(name)", withExtension: "bin") { return bundled }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/Models/ggml-\(name).bin")
    }
```

Call `rebuildPipeline()` at the end of `applicationDidFinishLaunching`, and again whenever Settings is closed (simplest: rebuild at the start of `toggle()`).

- [ ] **Step 2: Handle the missing-key case in `toggle()`** — before recording:

```swift
        guard !(keychain.get() ?? "").isEmpty else {
            openSettings()
            return
        }
```

- [ ] **Step 3: Build and full manual verification (no env key)**

Launch the app normally (no `ANTHROPIC_API_KEY`). With the key saved in Settings:
1. Click into Slack, dictate, pick a variant → it pastes.
2. Change the whisper model in Settings to `small` (download it first: `./scripts/download-model.sh small`), relaunch, confirm transcription still works.
3. Delete the key in Settings → triggering the hotkey opens Settings instead of failing silently.

**Phase 3 / MVP gate:** the app runs with no hardcoded secrets, key lives in Keychain, model is selectable, permissions are guided, and the full loop works for real Slack messages.

- [ ] **Step 4: Commit**

```bash
git add Sources/CrispVoice/App/AppDelegate.swift
git commit -m "feat: load key from Keychain + selectable whisper model — MVP complete (Phase 3.5)"
```

---

## Task 3.6: Run the full test suite + tag the MVP

**Files:** none (verification + tag)

- [ ] **Step 1: Run all unit tests**

Run: `xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test`
Expected: PASS across PasteboardTests, AudioConverterTests, CrispPromptTests, CrispResultTests, AnthropicClientTests, CrispEngineTests, KeychainStoreTests, PreferencesTests.

- [ ] **Step 2: Push and tag**

```bash
git push
git tag v0.1.0-mvp
git push --tags
```

- [ ] **Step 3: Manual smoke test of the privacy promise**

With Little Snitch / `nettop` (or `sudo lsof -i -nP | grep CrispVoice`) open, run one full loop and confirm the only outbound connection from CrispVoice is to `api.anthropic.com` — no other host, and none during recording/transcription.

---

## Notes on later phases (not in this plan)

- **Phase 4 (public BYOK release):** Apple Developer Program, code-signing + notarization, bundling the chosen whisper model into the `.app` Resources (replacing the dev `Models/` path lookups), a download page / GitHub Release, Sparkle auto-update, and a written privacy statement. Gets its own plan.
- **Phase 5 (optional):** managed backend + subscription, a Slack-native Marketplace app, or a fully-offline local-LLM rewrite mode. Each its own spec → plan.
