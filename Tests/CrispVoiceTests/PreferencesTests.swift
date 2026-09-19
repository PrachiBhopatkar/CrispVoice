import XCTest
@testable import CrispVoice

final class PreferencesTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "com.crispvoice.tests.preferences.\(UUID().uuidString)")!
    }

    func test_defaults_areSensible() {
        let prefs = Preferences(defaults: freshDefaults())

        XCTAssertEqual(prefs.modelName, "claude-haiku-4-5-20251001")
        XCTAssertEqual(prefs.variantCount, 3)
    }

    func test_setters_persist() {
        let defaults = freshDefaults()
        let prefs = Preferences(defaults: defaults)

        prefs.modelName = "claude-sonnet-4-5-20250929"
        prefs.variantCount = 2

        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.modelName, "claude-sonnet-4-5-20250929")
        XCTAssertEqual(reloaded.variantCount, 2)
    }

    // MARK: - Provider selection

    func test_missingProvider_defaultsToAnthropic() {
        let prefs = Preferences(defaults: freshDefaults())

        XCTAssertEqual(prefs.rewriteProvider, .anthropic)
    }

    func test_unknownStoredProvider_fallsBackToAnthropicWithoutDeletingEitherProvidersData() {
        let defaults = freshDefaults()
        defaults.set("some-unknown-provider", forKey: "rewriteProvider")
        defaults.set("claude-sonnet-4-5-20250929", forKey: "anthropicModelName")
        defaults.set("my-profile", forKey: "bedrockProfileName")
        defaults.set("us-west-2", forKey: "bedrockRegion")
        defaults.set("us.anthropic.claude-opus-4-8", forKey: "bedrockModelID")

        let prefs = Preferences(defaults: defaults)

        XCTAssertEqual(prefs.rewriteProvider, .anthropic)
        // Reading the unknown provider must not have deleted or rewritten
        // either provider's stored data.
        XCTAssertEqual(defaults.string(forKey: "rewriteProvider"), "some-unknown-provider")
        XCTAssertEqual(prefs.anthropicModelName, "claude-sonnet-4-5-20250929")
        XCTAssertEqual(prefs.bedrockProfileName, "my-profile")
        XCTAssertEqual(prefs.bedrockRegion, "us-west-2")
        XCTAssertEqual(prefs.bedrockModelID, "us.anthropic.claude-opus-4-8")
    }

    // MARK: - Independent persistence

    func test_anthropicAndBedrockSettingsAndVariantCount_persistIndependently() {
        let defaults = freshDefaults()
        let prefs = Preferences(defaults: defaults)

        prefs.rewriteProvider = .bedrock
        prefs.anthropicModelName = "claude-sonnet-4-5-20250929"
        prefs.bedrockProfileName = "work"
        prefs.bedrockRegion = "eu-central-1"
        prefs.bedrockModelID = "us.anthropic.claude-opus-4-8"
        prefs.variantCount = 5

        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.rewriteProvider, .bedrock)
        XCTAssertEqual(reloaded.anthropicModelName, "claude-sonnet-4-5-20250929")
        XCTAssertEqual(reloaded.bedrockProfileName, "work")
        XCTAssertEqual(reloaded.bedrockRegion, "eu-central-1")
        XCTAssertEqual(reloaded.bedrockModelID, "us.anthropic.claude-opus-4-8")
        XCTAssertEqual(reloaded.variantCount, 5)

        // Changing one provider's settings must not disturb the other's.
        reloaded.anthropicModelName = "claude-haiku-4-5-20251001"
        XCTAssertEqual(reloaded.bedrockProfileName, "work")
        XCTAssertEqual(reloaded.bedrockRegion, "eu-central-1")
        XCTAssertEqual(reloaded.bedrockModelID, "us.anthropic.claude-opus-4-8")
    }

    // MARK: - Legacy model migration

    func test_firstInitialization_copiesLegacyModelNameToAbsentAnthropicModelName_leavesModelNameUntouched() {
        let defaults = freshDefaults()
        defaults.set("legacy-model-name", forKey: "modelName")
        XCTAssertNil(defaults.string(forKey: "anthropicModelName"))

        let prefs = Preferences(defaults: defaults)

        XCTAssertEqual(prefs.anthropicModelName, "legacy-model-name")
        XCTAssertEqual(defaults.string(forKey: "modelName"), "legacy-model-name")
        XCTAssertEqual(prefs.modelName, "legacy-model-name")
    }

    func test_existingAnthropicModelName_winsOverLegacyModelName() {
        let defaults = freshDefaults()
        defaults.set("legacy-model-name", forKey: "modelName")
        defaults.set("already-chosen-model", forKey: "anthropicModelName")

        let prefs = Preferences(defaults: defaults)

        XCTAssertEqual(prefs.anthropicModelName, "already-chosen-model")
        XCTAssertEqual(defaults.string(forKey: "modelName"), "legacy-model-name")
    }

    func test_bothModelKeysAbsent_returnsAnthropicDefault() {
        let prefs = Preferences(defaults: freshDefaults())

        XCTAssertEqual(prefs.anthropicModelName, "claude-haiku-4-5-20251001")
    }

    // MARK: - Bedrock profile/model defaults

    func test_blankOrWhitespaceBedrockProfile_readsAsDefault() {
        let defaults = freshDefaults()
        defaults.set("   ", forKey: "bedrockProfileName")
        let prefs = Preferences(defaults: defaults)

        XCTAssertEqual(prefs.bedrockProfileName, "default")

        prefs.bedrockProfileName = "\t\n "
        XCTAssertEqual(prefs.bedrockProfileName, "default")
        XCTAssertEqual(defaults.string(forKey: "bedrockProfileName"), "default")
    }

    func test_absentBedrockModel_readsAsOpusPreset() {
        let prefs = Preferences(defaults: freshDefaults())

        XCTAssertEqual(prefs.bedrockModelID, "us.anthropic.claude-opus-4-8")
    }

    // MARK: - BedrockModelOption

    func test_opusPreset_resolvesExactlyToItsModelID() {
        XCTAssertEqual(BedrockModelOption.opus48US.resolvedModelID, "us.anthropic.claude-opus-4-8")
        XCTAssertEqual(BedrockModelOption.opus48USModelID, "us.anthropic.claude-opus-4-8")
    }

    func test_customModelNormalization_trimsOnlyLeadingTrailingWhitespace() {
        let option = BedrockModelOption.custom("  company.custom-model:v2  ")

        XCTAssertEqual(option.resolvedModelID, "company.custom-model:v2")

        let internalWhitespace = BedrockModelOption.custom("  arn:aws:bedrock: us-east-1 :123:inference-profile/foo  ")
        XCTAssertEqual(internalWhitespace.resolvedModelID, "arn:aws:bedrock: us-east-1 :123:inference-profile/foo")
    }

    // MARK: - BedrockConfiguration validation

    func test_blankRegionOrModel_bedrockConfigurationThrowsMissingConfiguration() {
        let defaults = freshDefaults()
        let prefs = Preferences(defaults: defaults)

        prefs.bedrockRegion = ""
        prefs.bedrockModelID = "us.anthropic.claude-opus-4-8"
        XCTAssertThrowsError(try prefs.bedrockConfiguration()) { error in
            XCTAssertEqual(error as? RewriteProviderError, .missingConfiguration)
        }

        prefs.bedrockRegion = "us-west-2"
        prefs.bedrockModelID = "   "
        XCTAssertThrowsError(try prefs.bedrockConfiguration()) { error in
            XCTAssertEqual(error as? RewriteProviderError, .missingConfiguration)
        }

        prefs.bedrockModelID = "us.anthropic.claude-opus-4-8"
        XCTAssertNoThrow(try prefs.bedrockConfiguration())
    }
}
