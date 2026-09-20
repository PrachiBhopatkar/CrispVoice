import Foundation
import Combine
import AppKit

extension Notification.Name {
    /// Posted only after a fully successful `SettingsModel.save()`. Carries
    /// no credential or configuration payload (`object` is always `nil` and
    /// `userInfo` is always `nil`) — observers must re-read `Preferences`/
    /// Keychain themselves rather than trust anything riding along on the
    /// notification (design section 5.2/9).
    static let crispVoiceRewriteConfigurationDidChange = Notification.Name("CrispVoiceRewriteConfigurationDidChange")
}

/// Injected seam for Test Connection so `SettingsModel` never talks to a
/// live network client directly, and tests can substitute recording fakes
/// for both providers.
protocol RewriteConnectionTesting {
    func testAnthropic(apiKey: String, model: String) async throws
    func testBedrock(configuration: BedrockConfiguration) async throws
}

/// Production `RewriteConnectionTesting`. Builds the draft-selected
/// low-level `TextCompleter` and sends the fixed connection probe (`Reply
/// with OK.` / `ping` / `maxTokens: 5`). Any response containing
/// non-whitespace text counts as success — exact `OK` equality is
/// intentionally never required (design section 7).
struct RewriteConnectionTester: RewriteConnectionTesting {
    static let probeSystem = "Reply with OK."
    static let probeUser = "ping"
    static let probeMaxTokens = 5

    let makeAnthropic: (String, String) -> TextCompleter
    let bedrockBuilder: BedrockClientBuilding

    func testAnthropic(apiKey: String, model: String) async throws {
        try await Self.probe(makeAnthropic(apiKey, model))
    }

    func testBedrock(configuration: BedrockConfiguration) async throws {
        try await Self.probe(try bedrockBuilder.make(configuration: configuration))
    }

    private static func probe(_ completer: TextCompleter) async throws {
        let response = try await completer.complete(
            system: probeSystem,
            user: probeUser,
            maxTokens: probeMaxTokens
        )
        guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RewriteProviderError.invalidResponse
        }
    }
}

/// Settings' model logic. All fields below are drafts: they live only in
/// this instance and never touch `UserDefaults`/Keychain until `save()`
/// succeeds. Closing Settings without saving simply discards the instance;
/// the next `SettingsModel()` reloads fresh drafts from persisted state
/// (design section 5.2).
@MainActor
final class SettingsModel: ObservableObject {
    struct ModelOption: Identifiable {
        let id: String
        let title: String
    }

    @Published var selectedProvider: RewriteProvider
    @Published var anthropicAPIKey: String
    @Published var anthropicModelName: String
    @Published var bedrockProfileName: String
    @Published var bedrockRegion: String
    @Published var bedrockModelOption: BedrockModelOption
    @Published var bedrockCustomModelID: String
    @Published var variantCount: Int
    @Published var validationMessage = ""
    @Published var isTesting = false

    let anthropicModelOptions: [ModelOption] = [
        ModelOption(id: "claude-haiku-4-5-20251001", title: "Claude Haiku 4.5"),
        ModelOption(id: "claude-sonnet-4-5-20250929", title: "Claude Sonnet 4.5")
    ]

    private let keychain: KeychainStore
    private let prefs: Preferences
    private let connectionTester: RewriteConnectionTesting

    init(
        keychain: KeychainStore = KeychainStore(),
        prefs: Preferences = Preferences(),
        connectionTester: RewriteConnectionTesting = RewriteConnectionTester(
            makeAnthropic: { apiKey, model in AnthropicClient(apiKey: apiKey, model: model) },
            bedrockBuilder: BedrockClientFactory()
        )
    ) {
        self.keychain = keychain
        self.prefs = prefs
        self.connectionTester = connectionTester

        self.selectedProvider = prefs.rewriteProvider
        self.anthropicAPIKey = keychain.get() ?? ""
        self.anthropicModelName = prefs.anthropicModelName
        self.bedrockProfileName = prefs.bedrockProfileName
        self.bedrockRegion = prefs.bedrockRegion
        self.variantCount = prefs.variantCount

        let storedModelOption = BedrockModelOption.from(modelID: prefs.bedrockModelID)
        self.bedrockModelOption = storedModelOption
        switch storedModelOption {
        case .opus48US:
            self.bedrockCustomModelID = ""
        case .custom(let identifier):
            self.bedrockCustomModelID = identifier
        }
    }

    func pasteAnthropicAPIKey() {
        if let value = NSPasteboard.general.string(forType: .string) {
            anthropicAPIKey = value
        }
    }

    /// Uses only the current in-memory drafts and the injected tester.
    /// Never persists anything to `UserDefaults`/Keychain, whether the
    /// probe succeeds or fails.
    func testConnection() async {
        validationMessage = ""
        isTesting = true
        defer { isTesting = false }

        do {
            switch selectedProvider {
            case .anthropic:
                let key = normalizedAnthropicAPIKey
                guard !key.isEmpty else {
                    validationMessage = "❌ Enter an Anthropic API key first."
                    return
                }
                try await connectionTester.testAnthropic(apiKey: key, model: anthropicModelName)
            case .bedrock:
                let configuration = try makeBedrockConfiguration()
                try await connectionTester.testBedrock(configuration: configuration)
            }
            validationMessage = "✅ Connection succeeded."
        } catch {
            validationMessage = Self.safeMessage(for: error)
        }
    }

    /// Validates locally, then performs the only throwing write — the
    /// Anthropic Keychain set/delete — first. Only if that succeeds does it
    /// write both providers' non-secret drafts and `variantCount` to
    /// `UserDefaults`, set the active `rewriteProvider` last, and post the
    /// content-free change notification. If the Keychain write throws, no
    /// preference or active-provider value changes (design section 5.2).
    func save() {
        validationMessage = ""

        switch selectedProvider {
        case .anthropic:
            guard !normalizedAnthropicAPIKey.isEmpty else {
                validationMessage = "❌ Enter an Anthropic API key first."
                return
            }
        case .bedrock:
            guard (try? makeBedrockConfiguration()) != nil else {
                validationMessage = Self.safeMessage(for: RewriteProviderError.missingConfiguration)
                return
            }
        }

        do {
            let normalizedKey = normalizedAnthropicAPIKey
            if normalizedKey.isEmpty {
                try keychain.delete()
            } else {
                try keychain.set(normalizedKey)
            }
        } catch {
            validationMessage = "❌ Unable to save your Anthropic API key."
            return
        }

        prefs.anthropicModelName = anthropicModelName
        prefs.bedrockProfileName = bedrockProfileName
        prefs.bedrockRegion = bedrockRegion
        prefs.bedrockModelID = effectiveBedrockModelID
        prefs.variantCount = variantCount
        prefs.rewriteProvider = selectedProvider

        NotificationCenter.default.post(
            name: .crispVoiceRewriteConfigurationDidChange,
            object: nil,
            userInfo: nil
        )

        validationMessage = "✅ Settings saved."
    }

    private var normalizedAnthropicAPIKey: String {
        anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The Bedrock model identifier the current drafts resolve to: the
    /// preset's fixed ID, or the free-form custom draft field.
    private var effectiveBedrockModelID: String {
        switch bedrockModelOption {
        case .opus48US:
            return BedrockModelOption.opus48USModelID
        case .custom:
            return bedrockCustomModelID
        }
    }

    private func makeBedrockConfiguration() throws -> BedrockConfiguration {
        try BedrockConfiguration(
            profileName: bedrockProfileName,
            region: bedrockRegion,
            modelID: effectiveBedrockModelID
        )
    }

    private static func safeMessage(for error: Error) -> String {
        if let providerError = error as? RewriteProviderError {
            return "❌ \(providerError.errorDescription ?? "Something went wrong. Please try again.")"
        }
        if let clientError = error as? AnthropicClient.ClientError {
            return "❌ \(clientError.errorDescription ?? "Something went wrong. Please try again.")"
        }
        return "❌ Something went wrong. Please try again."
    }
}
