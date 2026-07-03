import SwiftUI
import AppKit

extension Notification.Name {
    static let crispVoiceAPIKeyDidChange = Notification.Name("CrispVoiceAPIKeyDidChange")
}

@MainActor
final class SettingsModel: ObservableObject {
    struct ModelOption: Identifiable {
        let id: String
        let title: String
    }

    @Published var apiKey: String
    @Published var modelName: String
    @Published var variantCount: Int
    @Published var validationMessage = ""
    @Published var isTesting = false

    let modelOptions: [ModelOption] = [
        ModelOption(id: "claude-haiku-4-5-20251001", title: "Claude Haiku 4.5"),
        ModelOption(id: "claude-sonnet-4-5-20250929", title: "Claude Sonnet 4.5")
    ]

    private let keychain: KeychainStore
    private let prefs: Preferences

    init(keychain: KeychainStore = KeychainStore(), prefs: Preferences = Preferences()) {
        self.keychain = keychain
        self.prefs = prefs
        self.apiKey = keychain.get() ?? ""
        self.modelName = prefs.modelName
        self.variantCount = prefs.variantCount
    }

    func save() {
        let normalizedKey = normalizedAPIKey()

        do {
            if normalizedKey.isEmpty {
                try keychain.delete()
            } else {
                try keychain.set(normalizedKey)
            }
            prefs.modelName = modelName
            prefs.variantCount = variantCount
            validationMessage = ""
            NotificationCenter.default.post(
                name: .crispVoiceAPIKeyDidChange,
                object: nil,
                userInfo: ["apiKey": normalizedKey]
            )
        } catch {
            validationMessage = "❌ Unable to save your API key."
        }
    }

    func savePreferences() {
        prefs.modelName = modelName
        prefs.variantCount = variantCount
    }

    func pasteAPIKey() {
        if let value = NSPasteboard.general.string(forType: .string) {
            apiKey = value
        }
    }

    func validate() async {
        let normalizedKey = normalizedAPIKey()
        guard !normalizedKey.isEmpty else {
            validationMessage = "❌ Enter an API key first."
            return
        }

        isTesting = true
        defer { isTesting = false }

        do {
            let client = AnthropicClient(apiKey: normalizedKey, model: modelName)
            _ = try await client.complete(system: "Reply with OK.", user: "ping", maxTokens: 5)
            validationMessage = "✅ Key works."
        } catch let error as AnthropicClient.ClientError {
            switch error {
            case .http(let statusCode, let message):
                validationMessage = "❌ HTTP \(statusCode): \(message)"
            case .badResponse:
                validationMessage = "❌ Anthropic returned an unexpected response."
            }
        } catch {
            validationMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func normalizedAPIKey() -> String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SettingsView: View {
    @StateObject private var model = SettingsModel()

    var body: some View {
        Form {
            Section("Anthropic") {
                SecureField("sk-ant-…", text: $model.apiKey)

                HStack(spacing: 12) {
                    Button("Paste") {
                        model.pasteAPIKey()
                    }

                    Button("Save") {
                        model.save()
                    }

                    Button("Test") {
                        Task { await model.validate() }
                    }
                    .disabled(model.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isTesting)

                    if model.isTesting {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if !model.validationMessage.isEmpty {
                    Text(model.validationMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("Rewrite") {
                Picker("Model", selection: $model.modelName) {
                    ForEach(model.modelOptions) { option in
                        Text(option.title).tag(option.id)
                    }
                }

                Stepper(value: $model.variantCount, in: 1...5) {
                    Text("Variants: \(model.variantCount)")
                }

                Text("Transcription uses Apple Speech. These settings only affect the Anthropic rewrite step.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(minWidth: 420, maxWidth: 420, minHeight: 260)
        .onChange(of: model.modelName) { _ in
            model.savePreferences()
        }
        .onChange(of: model.variantCount) { _ in
            model.savePreferences()
        }
    }
}
