import Foundation

/// Selects and constructs the runtime `TextCompleter` for the active rewrite
/// provider. This is the single seam `AppDelegate` uses to turn
/// `Preferences.rewriteProvider` into a concrete completer — it never picks
/// a provider itself (that is `Preferences.rewriteProvider`'s job, which
/// already falls back to `.anthropic` for a missing/unknown stored value —
/// design section 12), and it never mutates `Preferences` or Keychain.
///
/// Bedrock selection never reads or requires the Anthropic Keychain key:
/// only the `.anthropic` branch below ever touches `keychain`/`environment`.
struct RewriteCompleterFactory {
    private let keychain: KeychainStore
    private let environment: [String: String]
    private let makeAnthropic: (String, String) -> TextCompleter
    private let bedrockBuilder: BedrockClientBuilding

    init(
        keychain: KeychainStore = KeychainStore(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        makeAnthropic: @escaping (String, String) -> TextCompleter = { apiKey, model in
            AnthropicClient(apiKey: apiKey, model: model)
        },
        bedrockBuilder: BedrockClientBuilding = BedrockClientFactory()
    ) {
        self.keychain = keychain
        self.environment = environment
        self.makeAnthropic = makeAnthropic
        self.bedrockBuilder = bedrockBuilder
    }

    /// Builds the completer for `preferences.rewriteProvider`. Throws
    /// `RewriteProviderError.missingConfiguration` when the active
    /// provider's local requirements are absent (no Anthropic key
    /// anywhere, or a blank Bedrock Region/model). Never mutates
    /// `preferences` or Keychain.
    func make(preferences: Preferences) throws -> TextCompleter {
        switch preferences.rewriteProvider {
        case .anthropic:
            guard let apiKey = resolvedAnthropicAPIKey() else {
                throw RewriteProviderError.missingConfiguration
            }
            return makeAnthropic(apiKey, preferences.anthropicModelName)
        case .bedrock:
            let configuration = try preferences.bedrockConfiguration()
            return try bedrockBuilder.make(configuration: configuration)
        }
    }

    /// Prefers the Keychain-stored key; falls back to `ANTHROPIC_API_KEY`
    /// only for development launches (design section 12) — never used to
    /// select Bedrock, and never consulted at all on the Bedrock path.
    private func resolvedAnthropicAPIKey() -> String? {
        if let stored = keychain.get()?.trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty {
            return stored
        }
        if let envKey = environment["ANTHROPIC_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !envKey.isEmpty {
            return envKey
        }
        return nil
    }
}
