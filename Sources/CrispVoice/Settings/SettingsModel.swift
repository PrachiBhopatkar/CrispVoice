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

    /// The Anthropic key value loaded from Keychain at `init`. `save()` only
    /// writes/deletes the Keychain entry when the current draft differs from
    /// this — never unconditionally on every Save. This also protects
    /// against `KeychainStore.get()` returning `nil` on any failure (not
    /// only "key absent"): without this guard, a transient read failure at
    /// Settings-open time would load an empty draft, and an unrelated
    /// Bedrock-only Save could then delete a real, previously-saved
    /// Anthropic key the user never touched.
    private let loadedAnthropicAPIKey: String

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
        let loadedKey = keychain.get() ?? ""
        self.loadedAnthropicAPIKey = loadedKey
        self.anthropicAPIKey = loadedKey
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

    /// Empties the draft only. The persisted Keychain entry is untouched
    /// until Save — matching the transactional draft model (design section
    /// 5.2). Save then deletes the persisted key because the normalized
    /// draft is empty.
    func clearAnthropicAPIKey() {
        anthropicAPIKey = ""
    }

    // MARK: - Bedrock UI-state (pure, presentation-only; no persistence)

    /// Whether the Bedrock model picker currently has "Custom…" selected.
    /// The Settings view uses this to decide whether to reveal the custom
    /// identifier field (design section 6/7).
    var isBedrockCustomModelSelected: Bool {
        if case .custom = bedrockModelOption {
            return true
        }
        return false
    }

    /// The exact Bedrock Runtime model/inference-profile identifier the
    /// current drafts resolve to. Exposes `effectiveBedrockModelID` for
    /// display (e.g. "Resolved model ID: …") without changing its
    /// persistence-time behavior.
    var bedrockResolvedModelID: String {
        effectiveBedrockModelID
    }

    /// The user-facing label for the currently selected Bedrock model
    /// option. Deliberately never includes the opaque custom identifier
    /// itself (which may be an ARN containing an AWS account ID) — only
    /// "Custom model" is ever shown for that case (design section 7/11).
    var bedrockModelDisplayLabel: String {
        switch bedrockModelOption {
        case .opus48US:
            return "Claude Opus 4.8 (US)"
        case .custom:
            return "Custom model"
        }
    }

    /// The AWS profile name to *display* when the draft is blank/whitespace
    /// — a presentation-only label. The value actually persisted/used for
    /// requests is always the lowercase `default` (see
    /// `bedrockResolvedProfileName`, `Preferences.bedrockProfileName`, and
    /// `BedrockConfiguration`'s own normalization).
    var bedrockProfileDisplayValue: String {
        let trimmed = bedrockProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Default" : trimmed
    }

    /// The AWS profile name Test Connection/Save actually resolve to for
    /// the current draft.
    var bedrockResolvedProfileName: String {
        Self.normalizedBedrockProfileName(bedrockProfileName)
    }

    /// A general cross-Region routing disclosure. Identical regardless of
    /// whether the Opus 4.8 (US) preset or a custom inference profile is
    /// selected — AWS may route content beyond the configured source
    /// Region for any geographic, global, or application inference
    /// profile, not only the preset (design section 6/7).
    var bedrockCrossRegionDisclosureText: String {
        "The configured Region is the source endpoint. Depending on the selected model or inference profile, AWS may route prompt and response content to other AWS-documented destination Regions for that profile."
    }

    /// Whether the current Bedrock drafts have enough local information for
    /// Test Connection to be worth attempting — a cheap, non-throwing mirror
    /// of `BedrockConfiguration`'s required fields (Region and model must be
    /// non-blank after trimming). Used only to enable/disable the Test
    /// button; it performs no normalization and never mutates state.
    var isBedrockDraftLocallyComplete: Bool {
        guard !bedrockRegion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        switch bedrockModelOption {
        case .opus48US:
            return true
        case .custom:
            return !bedrockCustomModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func normalizedBedrockProfileName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "default" : trimmed
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
                validationMessage = "✅ Connection succeeded."
            case .bedrock:
                let configuration = try makeBedrockConfiguration()
                try await connectionTester.testBedrock(configuration: configuration)
                // Reports provider, Region, and model label only — never
                // the AWS profile/account or an opaque custom identifier
                // (design section 7/11).
                validationMessage = "✅ Connection succeeded. \(RewriteProvider.bedrock.title) (\(configuration.region)) using \(bedrockModelDisplayLabel)."
            }
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
            if normalizedKey != loadedAnthropicAPIKey {
                if normalizedKey.isEmpty {
                    try keychain.delete()
                } else {
                    try keychain.set(normalizedKey)
                }
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
            return BedrockModelOption.custom(bedrockCustomModelID).resolvedModelID
        }
    }

    private func makeBedrockConfiguration() throws -> BedrockConfiguration {
        try BedrockConfiguration(
            profileName: bedrockProfileName,
            region: bedrockRegion,
            modelID: effectiveBedrockModelID
        )
    }

    /// Delegates to the same `SafeErrorPresenter` seam `AppDelegate` uses,
    /// so Settings' error display and `DebugLog`'s content-free logging stay
    /// in lockstep with a single translation: `RewriteProviderError` and
    /// `AnthropicClient.ClientError` get their fixed, status/category-only
    /// safe message (never a raw AWS/Anthropic error, credential, or server
    /// body); anything else gets a generic message. `writeDiagnostic` is a
    /// no-op here — Settings' own validation/test-connection UI is not an
    /// application failure path and does not write to `DebugLog`.
    private static func safeMessage(for error: Error) -> String {
        let presentation = SafeErrorPresenter(writeDiagnostic: { _ in }).present(error)
        return "❌ \(presentation.userMessage)"
    }
}
