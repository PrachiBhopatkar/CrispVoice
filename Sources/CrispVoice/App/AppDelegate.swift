import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let hotkeys = HotkeyManager()
    private let inserter = Inserter()
    private let recorder = AudioRecorder()
    private var pendingTargetApp: NSRunningApplication?
    private lazy var transcriber = Transcriber(modelURL: Self.devModelURL())
    private lazy var engine = CrispEngine(
        completer: AnthropicClient(
            apiKey: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "",
            model: "claude-haiku-4-5"
        ),
        variantCount: 1
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎙️"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        hotkeys.register { [weak self] in
            Task { @MainActor in
                self?.toggle()
            }
        }
    }

    private func toggle() {
        if recorder.isRecording {
            statusItem.button?.title = "⏳"
            pendingTargetApp = NSWorkspace.shared.frontmostApplication
            if let target = pendingTargetApp {
                NSLog("CrispVoice: target_capture bundle=%@ pid=%d", target.bundleIdentifier ?? "<unknown>", target.processIdentifier)
            }
            let frames = recorder.stop()
            NSLog("CrispVoice: record_stop frames=%d", frames.count)
            Task { await process(frames) }
            return
        }

        do {
            try recorder.start()
            statusItem.button?.title = "🔴"
        } catch {
            statusItem.button?.title = "🎙️"
        }
    }

    private func process(_ frames: [Float]) async {
        do {
            let transcript = try await transcriber.transcribe(frames)
            guard !transcript.isEmpty else {
                NSLog("CrispVoice: transcribe_empty")
                return
            }

            NSLog("CrispVoice: transcribe_ok chars=%d", transcript.count)

            let result = try await engine.crisp(transcript: transcript, tone: .neutral)
            NSLog("CrispVoice: crisp_ok variants=%d", result.variants.count)

            if let best = result.variants.first {
                let current = NSWorkspace.shared.frontmostApplication
                NSLog("CrispVoice: preinsert_frontmost bundle=%@ pid=%d", current?.bundleIdentifier ?? "<unknown>", current?.processIdentifier ?? 0)

                if let target = pendingTargetApp,
                   current?.processIdentifier != target.processIdentifier {
                    _ = await MainActor.run {
                        target.activate(options: [.activateIgnoringOtherApps])
                    }
                    NSLog("CrispVoice: target_reactivated bundle=%@ pid=%d", target.bundleIdentifier ?? "<unknown>", target.processIdentifier)
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    let verified = NSWorkspace.shared.frontmostApplication
                    NSLog("CrispVoice: postreactivate_frontmost bundle=%@ pid=%d", verified?.bundleIdentifier ?? "<unknown>", verified?.processIdentifier ?? 0)
                }

                NSLog("CrispVoice: insert_attempt chars=%d", best.count)
                await MainActor.run {
                    inserter.insert(best)
                }
            }
        } catch {
            log(error: error)
        }

        pendingTargetApp = nil

        await MainActor.run {
            if !self.recorder.isRecording {
                self.statusItem.button?.title = "🎙️"
            }
        }
    }

    private static func devModelURL() -> URL {
        if let bundled = Bundle.main.url(forResource: "ggml-base", withExtension: "bin") {
            return bundled
        }

        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/Models/ggml-base.bin")
    }

    private func log(error: Error) {
        switch error {
        case let AnthropicClient.ClientError.http(status, message):
            NSLog("CrispVoice: anthropic_http status=%d message=%@", status, message)
        case AnthropicClient.ClientError.badResponse:
            NSLog("CrispVoice: anthropic_bad_response")
        case CrispResult.ParseError.noJSONObject:
            NSLog("CrispVoice: parse_no_json")
        case CrispResult.ParseError.decodeFailed:
            NSLog("CrispVoice: parse_decode_failed")
        default:
            NSLog("CrispVoice: error_type=%@", String(reflecting: type(of: error)))
        }
    }
}
