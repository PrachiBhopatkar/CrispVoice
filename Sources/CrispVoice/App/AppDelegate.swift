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
    private let appBundleIdentifier = Bundle.main.bundleIdentifier
    private let slackBundleIdentifier = "com.tinyspeck.slackmacgap"
    private let hotkeys = HotkeyManager()
    private let inserter = Inserter()
    private let recorder = AudioRecorder()
    private var targetApp: NSRunningApplication?
    private let transcriber = Transcriber()
    private let keychain = KeychainStore()
    private let prefs = Preferences()
    private var cachedAPIKey: String?

    private let model = SuggestionModel()
    private var panel: CapturePanel<SuggestionView>!
    private var lastTranscript = ""
    private var isPreparingCapture = false
    private let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugLog.reset()
        DebugLog.write("AppDelegate.applicationDidFinishLaunching")
        DebugLog.write("AppDelegate.bundlePath path=\(Bundle.main.bundlePath)")
        DebugLog.write("AppDelegate.bundleIdentifier id=\(Bundle.main.bundleIdentifier ?? "nil")")
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAPIKeyChanged(_:)),
            name: .crispVoiceAPIKeyDidChange,
            object: nil
        )

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

        guard !isRunningTests else {
            DebugLog.write("AppDelegate.applicationDidFinishLaunching skippingPermissionPromptsForTests")
            return
        }

        if !PermissionsManager.hasAccessibility() {
            PermissionsManager.requestAccessibility()
        }

        Task {
            _ = await PermissionsManager.requestMicrophone()
            _ = await PermissionsManager.requestSpeechRecognition()
        }
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
        targetApp = captureTargetApplication()
        DebugLog.write("AppDelegate.startCapture targetApp=\(targetApp?.bundleIdentifier ?? "nil")")
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
                        DebugLog.write(
                            "AppDelegate.partialTranscript length=\(transcript.count) fp=\(DebugLog.fingerprint(transcript))"
                        )
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
            DebugLog.write(
                "AppDelegate.finalTranscript length=\(transcript.count) fp=\(DebugLog.fingerprint(transcript))"
            )
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
            DebugLog.write(
                "AppDelegate.runCrisp tone=\(tone.rawValue) transcriptLength=\(lastTranscript.count) transcriptFP=\(DebugLog.fingerprint(lastTranscript))"
            )
            let engine = try makeEngine()
            let result = try await engine.crisp(transcript: lastTranscript, tone: tone)
            await MainActor.run {
                DebugLog.write("AppDelegate.runCrisp variants=\(result.variants.count)")
                self.model.variants = result.variants
                self.model.status = ""
                self.model.isWorking = false
            }
        } catch { await fail(error) }
    }

    private func send(_ text: String) {
        guard PermissionsManager.hasAccessibility() else {
            DebugLog.write("AppDelegate.send accessibilityDenied textLength=\(text.count)")
            model.status = "Enable Accessibility to paste into Slack."
            PermissionsManager.openAccessibilitySettings()
            return
        }

        panel.dismiss()
        let resolvedTargetApp = targetApp ?? captureTargetApplication()
        DebugLog.write(
            "AppDelegate.send targetApp=\(resolvedTargetApp?.bundleIdentifier ?? "nil") frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil") textLength=\(text.count)"
        )

        Task { @MainActor in
            if let resolvedTargetApp {
                resolvedTargetApp.activate(options: [.activateIgnoringOtherApps])
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            DebugLog.write("AppDelegate.send dispatchPaste frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")")
            inserter.insert(text)
        }
    }

    private func captureTargetApplication() -> NSRunningApplication? {
        if let frontmostApp = NSWorkspace.shared.frontmostApplication,
           !isOwnApp(frontmostApp) {
            return frontmostApp
        }

        if let targetApp, !isOwnApp(targetApp) {
            return targetApp
        }

        return NSRunningApplication
            .runningApplications(withBundleIdentifier: slackBundleIdentifier)
            .first(where: { !$0.isTerminated })
    }

    private func isOwnApp(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier == appBundleIdentifier
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
        if let cachedAPIKey, !cachedAPIKey.isEmpty {
            DebugLog.write("AppDelegate.currentAPIKey usingCachedKey")
            return cachedAPIKey
        }

        let storedKey = keychain.get()?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let storedKey, !storedKey.isEmpty {
            DebugLog.write("AppDelegate.currentAPIKey usingKeychain")
            cachedAPIKey = storedKey
            return storedKey
        }

        let envKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let envKey, !envKey.isEmpty {
            DebugLog.write("AppDelegate.currentAPIKey usingEnvironment")
            cachedAPIKey = envKey
            return envKey
        }

        DebugLog.write("AppDelegate.currentAPIKey missing")
        return nil
    }

    @objc
    private func handleAPIKeyChanged(_ notification: Notification) {
        let updatedKey = notification.userInfo?["apiKey"] as? String
        let normalized = updatedKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        cachedAPIKey = (normalized?.isEmpty == false) ? normalized : nil
        DebugLog.write("AppDelegate.handleAPIKeyChanged cached=\(cachedAPIKey != nil)")
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "CrispVoice Settings"
            window.styleMask = NSWindow.StyleMask([.titled, .closable])
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 460, height: 320))
            window.minSize = NSSize(width: 460, height: 320)
            window.center()
            settingsWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
