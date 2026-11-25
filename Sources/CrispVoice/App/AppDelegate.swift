import AppKit
import SwiftUI

/// A closed, locally-authored error with a fixed, hardcoded message — no
/// interpolated/dynamic content, same shape as `RewriteProviderError` and
/// `AnthropicClient.ClientError`. Declared at module scope (rather than
/// private/nested in `AppDelegate`) so `SafeErrorPresenter` can recognize
/// and trust it as a fourth safe-to-display error type.
enum AppDelegateError: LocalizedError {
    case microphoneAccessDenied
    case missingAnthropicAPIKey
    case accessibilityRequired

    /// A stable diagnostic category safe to write to `DebugLog`.
    var diagnosticCode: String {
        switch self {
        case .microphoneAccessDenied:
            return "microphone_access_denied"
        case .missingAnthropicAPIKey:
            return "missing_anthropic_api_key"
        case .accessibilityRequired:
            return "accessibility_required"
        }
    }

    var errorDescription: String? {
        switch self {
        case .microphoneAccessDenied:
            return "Enable Microphone access for CrispVoice in System Settings to dictate."
        case .missingAnthropicAPIKey:
            return "Set your Anthropic API key in Settings to continue."
        case .accessibilityRequired:
            return "CrispVoice needs Accessibility permission to paste into other apps. Turn it on for CrispVoice in System Settings, then press the hotkey again."
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private let appBundleIdentifier = Bundle.main.bundleIdentifier
    private let slackBundleIdentifier = "com.tinyspeck.slackmacgap"
    private let hotkeys = HotkeyManager()
    private let inserter = Inserter()
    private let recorder = AudioRecorder()
    private var targetApp: NSRunningApplication?
    private let transcriber = Transcriber()
    private let prefs = Preferences()
    private let completerFactory = RewriteCompleterFactory()
    private let errorPresenter = SafeErrorPresenter(writeDiagnostic: DebugLog.write)

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
        ToolPath.applyToProcessEnvironment()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRewriteConfigurationChanged(_:)),
            name: .crispVoiceRewriteConfigurationDidChange,
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
            let microphoneGranted = await PermissionsManager.requestMicrophone()
            DebugLog.write("AppDelegate.microphonePermission granted=\(microphoneGranted)")
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
            guard PermissionsManager.hasAccessibility() else {
                let presentation = errorPresenter.present(AppDelegateError.accessibilityRequired)
                model.isWorking = false
                model.variants = []
                model.status = presentation.userMessage
                panel.present()
                PermissionsManager.openAccessibilitySettings()
                return
            }
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

            guard await PermissionsManager.requestMicrophone() else {
                await fail(AppDelegateError.microphoneAccessDenied)
                await MainActor.run {
                    self.statusItem.button?.title = "🎙️"
                }
                self.isPreparingCapture = false
                return
            }

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

    /// The single failure boundary for every capture/transcribe/rewrite
    /// error. `SafeErrorPresenter` is the only thing that ever writes a
    /// diagnostic line here. It trusts only a closed set of locally-authored
    /// error types with fixed, hardcoded messages (`RewriteProviderError`,
    /// `AnthropicClient.ClientError`, `TranscriberError`, `AppDelegateError`)
    /// and never inspects any other, untrusted error's own
    /// message/description — so no provider value, profile, Region, model,
    /// credential, transcript, or response can reach `DebugLog` or the UI
    /// through this path.
    private func fail(_ error: Error) async {
        let presentation = errorPresenter.present(error)
        await MainActor.run {
            self.model.isWorking = false
            self.model.status = "Error: \(presentation.userMessage)"
        }
    }

    /// Builds a fresh completer for the currently active rewrite provider on
    /// every call — there is no cached engine/API key to go stale, so a
    /// Settings change always takes effect on the very next crisp request
    /// without needing to inspect the change-notification's payload (it
    /// carries none).
    private func makeEngine() throws -> CrispEngine {
        CrispEngine(
            completer: try completerFactory.make(preferences: prefs),
            variantCount: prefs.variantCount
        )
    }

    /// Posted only after a successful Settings save, with no payload
    /// (`object`/`userInfo` are always `nil`). Nothing here needs to read
    /// the notification: `makeEngine()` above already re-resolves the
    /// active provider, model, and credentials from `Preferences`/Keychain
    /// on every call.
    @objc
    private func handleRewriteConfigurationChanged(_ notification: Notification) {
        DebugLog.write("AppDelegate.handleRewriteConfigurationChanged")
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

        // Rebuild the root view (and its @StateObject SettingsModel) on every
        // open so a draft abandoned by closing without Save never reappears
        // on the next open (design section 5.2: "Closing Settings without
        // Save discards drafts"). Reusing the cached window/NSHostingController
        // instance (rather than recreating the NSWindow) preserves its frame
        // and other window-level state across opens.
        settingsWindow?.contentViewController = NSHostingController(rootView: SettingsView())

        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
