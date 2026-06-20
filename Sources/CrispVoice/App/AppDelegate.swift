import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let hotkeys = HotkeyManager()
    private let inserter = Inserter()
    private let recorder = AudioRecorder()
    private var targetApp: NSRunningApplication?
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
            targetApp = NSWorkspace.shared.frontmostApplication
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

    private static func devModelURL() -> URL {
        if let bundled = Bundle.main.url(forResource: "ggml-base", withExtension: "bin") { return bundled }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/Models/ggml-base.bin")
    }
}
