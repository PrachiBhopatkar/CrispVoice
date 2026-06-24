import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum AppDelegateError: LocalizedError {
        case missingAPIKey

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Set your Anthropic API key in Settings to continue."
            }
        }
    }

    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private let hotkeys = HotkeyManager()
    private let inserter = Inserter()
    private let recorder = AudioRecorder()
    private var targetApp: NSRunningApplication?
    private let transcriber = Transcriber()
    private let keychain = KeychainStore()
    private let prefs = Preferences()

    private let model = SuggestionModel()
    private var panel: CapturePanel<SuggestionView>!
    private var lastTranscript = ""
    private var isPreparingCapture = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎙️"
        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
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
            _ = recorder.stop()
            recorder.onAudioBufferCaptured = nil
            model.isWorking = true
            model.variants = []
            model.status = "Finalizing transcript…"
            Task {
                await self.finalizeTranscriptThenCrisp()
            }
        } else {
            startCapture()
        }
    }

    private func startCapture() {
        guard !isPreparingCapture else { return }

        isPreparingCapture = true
        targetApp = NSWorkspace.shared.frontmostApplication
        lastTranscript = ""
        model.transcript = ""
        model.variants = []
        model.isWorking = false
        model.status = "Listening…"
        panel.present()

        Task { [weak self] in
            guard let self else { return }
            do {
                try await transcriber.startLiveTranscription { [weak self] transcript in
                    Task { @MainActor in
                        guard let self else { return }
                        self.lastTranscript = transcript
                        self.model.transcript = transcript
                    }
                }
                recorder.onAudioBufferCaptured = { [weak self] buffer in
                    self?.transcriber.appendAudioBuffer(buffer)
                }
                try recorder.start()
                await MainActor.run {
                    self.statusItem.button?.title = "🔴"
                }
            } catch {
                transcriber.cancel()
                await fail(error)
                await MainActor.run {
                    self.panel.dismiss()
                    self.statusItem.button?.title = "🎙️"
                }
            }

            self.isPreparingCapture = false
        }
    }

    private func finalizeTranscriptThenCrisp() async {
        defer {
            Task { @MainActor in
                self.statusItem.button?.title = "🎙️"
            }
        }
        do {
            let transcript = try await transcriber.finishTranscription()
            lastTranscript = transcript
            await MainActor.run {
                self.model.transcript = transcript
                self.model.variants = []
                self.model.status = "Crisping…"
            }
            await runCrisp(tone: .neutral)
        } catch { await fail(error) }
    }

    private func rerun(tone: Tone) {
        guard !lastTranscript.isEmpty else { return }
        model.isWorking = true
        model.status = "Crisping…"
        Task { await runCrisp(tone: tone) }
    }

    private func runCrisp(tone: Tone) async {
        do {
            let engine = try makeEngine()
            let result = try await engine.crisp(transcript: lastTranscript, tone: tone)
            await MainActor.run {
                self.model.variants = result.variants
                self.model.status = ""
                self.model.isWorking = false
            }
        } catch { await fail(error) }
    }

    private func send(_ text: String) {
        panel.dismiss()
        Task { @MainActor in
            if let targetApp {
                targetApp.activate(options: [.activateIgnoringOtherApps])
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            inserter.insert(text)
        }
    }

    private func fail(_ error: Error) async {
        await MainActor.run {
            self.model.isWorking = false
            self.model.status = "Error: \(error.localizedDescription)"
        }
    }

    private func makeEngine() throws -> CrispEngine {
        guard let apiKey = currentAPIKey() else {
            throw AppDelegateError.missingAPIKey
        }

        return CrispEngine(
            completer: AnthropicClient(apiKey: apiKey, model: prefs.modelName),
            variantCount: prefs.variantCount
        )
    }

    private func currentAPIKey() -> String? {
        let storedKey = keychain.get()?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let storedKey, !storedKey.isEmpty {
            return storedKey
        }

        let envKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let envKey, !envKey.isEmpty {
            return envKey
        }

        return nil
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "CrispVoice Settings"
            window.styleMask = NSWindow.StyleMask([.titled, .closable])
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
