import Foundation

final class Preferences {
    private enum Keys {
        static let modelName = "modelName"
        static let variantCount = "variantCount"
        static let rewriteProvider = "rewriteProvider"
        static let anthropicModelName = "anthropicModelName"
        static let bedrockProfileName = "bedrockProfileName"
        static let bedrockRegion = "bedrockRegion"
        static let bedrockModelID = "bedrockModelID"
    }

    private static let anthropicDefaultModelName = "claude-haiku-4-5-20251001"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // One-time legacy migration: copy the legacy Anthropic model name
        // into the provider-specific key the first time it is absent.
        // `modelName` itself is never deleted or rewritten (design section
        // 5.2 / 12).
        if defaults.string(forKey: Keys.anthropicModelName) == nil,
           let legacyModelName = defaults.string(forKey: Keys.modelName) {
            defaults.set(legacyModelName, forKey: Keys.anthropicModelName)
        }
    }

    var modelName: String {
        get { defaults.string(forKey: Keys.modelName) ?? Self.anthropicDefaultModelName }
        set { defaults.set(newValue, forKey: Keys.modelName) }
    }

    var variantCount: Int {
        get { defaults.object(forKey: Keys.variantCount) as? Int ?? 3 }
        set { defaults.set(newValue, forKey: Keys.variantCount) }
    }

    /// The active rewrite provider. A missing, unknown, or corrupt stored
    /// value resolves to `.anthropic` without rewriting or deleting either
    /// provider's stored settings.
    var rewriteProvider: RewriteProvider {
        get {
            guard let raw = defaults.string(forKey: Keys.rewriteProvider),
                  let provider = RewriteProvider(rawValue: raw) else {
                return .anthropic
            }
            return provider
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.rewriteProvider) }
    }

    /// The Anthropic model identifier. Falls back to the legacy `modelName`
    /// value (copied once at `init`) and finally to the current Anthropic
    /// default when neither key is present.
    var anthropicModelName: String {
        get { defaults.string(forKey: Keys.anthropicModelName) ?? Self.anthropicDefaultModelName }
        set { defaults.set(newValue, forKey: Keys.anthropicModelName) }
    }

    /// The AWS profile name shown/used for Bedrock. A blank or
    /// whitespace-only value always reads and is stored as `default`.
    var bedrockProfileName: String {
        get {
            guard let stored = defaults.string(forKey: Keys.bedrockProfileName) else {
                return "default"
            }
            let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "default" : trimmed
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(trimmed.isEmpty ? "default" : trimmed, forKey: Keys.bedrockProfileName)
        }
    }

    /// The AWS Region used for Bedrock requests. Empty when not yet
    /// configured; required before Bedrock can be activated. Only
    /// leading/trailing whitespace is trimmed on write, matching
    /// `BedrockConfiguration`'s own normalization.
    var bedrockRegion: String {
        get { defaults.string(forKey: Keys.bedrockRegion) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.bedrockRegion) }
    }

    /// The Bedrock model or inference-profile identifier. Defaults to the
    /// Claude Opus 4.8 (US) preset when absent. Only leading/trailing
    /// whitespace is trimmed on write, matching `BedrockConfiguration`'s own
    /// normalization; internal characters of a custom identifier are never
    /// rewritten.
    var bedrockModelID: String {
        get { defaults.string(forKey: Keys.bedrockModelID) ?? BedrockModelOption.opus48USModelID }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.bedrockModelID) }
    }

    /// Builds a validated `BedrockConfiguration` from the current Bedrock
    /// preference drafts, throwing `.missingConfiguration` if the Region or
    /// model is blank.
    func bedrockConfiguration() throws -> BedrockConfiguration {
        try BedrockConfiguration(profileName: bedrockProfileName, region: bedrockRegion, modelID: bedrockModelID)
    }
}
