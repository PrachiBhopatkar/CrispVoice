import XCTest
@testable import CrispVoice

final class RewriteCompleterFactoryTests: XCTestCase {

    // MARK: - Fakes

    private final class FakeKeychainBackend {
        var storage: [String: Data] = [:]
        private(set) var copyMatchingCallCount = 0

        func add(query: CFDictionary, _: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
            let dict = query as NSDictionary
            guard
                let service = dict[kSecAttrService as String] as? String,
                let account = dict[kSecAttrAccount as String] as? String,
                let data = dict[kSecValueData as String] as? Data
            else { return errSecParam }
            storage[key(service: service, account: account)] = data
            return errSecSuccess
        }

        func copyMatching(query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
            copyMatchingCallCount += 1
            let dict = query as NSDictionary
            guard
                let service = dict[kSecAttrService as String] as? String,
                let account = dict[kSecAttrAccount as String] as? String
            else { return errSecParam }
            guard let data = storage[key(service: service, account: account)] else {
                return errSecItemNotFound
            }
            result?.pointee = data as CFTypeRef
            return errSecSuccess
        }

        func delete(query: CFDictionary) -> OSStatus {
            let dict = query as NSDictionary
            guard
                let service = dict[kSecAttrService as String] as? String,
                let account = dict[kSecAttrAccount as String] as? String
            else { return errSecParam }
            let resolvedKey = key(service: service, account: account)
            if storage.removeValue(forKey: resolvedKey) == nil { return errSecItemNotFound }
            return errSecSuccess
        }

        private func key(service: String, account: String) -> String { "\(service)::\(account)" }
    }

    private final class RecordingCompleter: TextCompleter {
        func complete(system: String, user: String, maxTokens: Int) async throws -> String { "" }
    }

    private final class FakeBedrockBuilder: BedrockClientBuilding {
        private(set) var configurations: [BedrockConfiguration] = []
        var shouldThrow: Error?
        let completer: TextCompleter = RecordingCompleter()

        func make(configuration: BedrockConfiguration) throws -> TextCompleter {
            configurations.append(configuration)
            if let shouldThrow { throw shouldThrow }
            return completer
        }
    }

    // MARK: - Helpers

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "com.crispvoice.tests.completerfactory.\(UUID().uuidString)")!
    }

    private func makeKeychainStore(backend: FakeKeychainBackend = FakeKeychainBackend()) -> KeychainStore {
        let service = "com.crispvoice.tests.completerfactory.\(UUID().uuidString)"
        let client = KeychainStore.SecurityClient(
            add: backend.add(query:_:),
            copyMatching: backend.copyMatching(query:result:),
            delete: backend.delete(query:)
        )
        return KeychainStore(service: service, securityClient: client)
    }

    // MARK: - Anthropic selection

    func test_anthropic_usesKeychainKeyAndAnthropicModelName() throws {
        let keychain = makeKeychainStore()
        try keychain.set("sk-from-keychain")

        let prefs = Preferences(defaults: freshDefaults())
        prefs.rewriteProvider = .anthropic
        prefs.anthropicModelName = "claude-sonnet-4-5-20250929"

        var capturedKeys: [String] = []
        var capturedModels: [String] = []
        let factory = RewriteCompleterFactory(
            keychain: keychain,
            environment: [:],
            makeAnthropic: { apiKey, model in
                capturedKeys.append(apiKey)
                capturedModels.append(model)
                return RecordingCompleter()
            },
            bedrockBuilder: FakeBedrockBuilder()
        )

        _ = try factory.make(preferences: prefs)

        XCTAssertEqual(capturedKeys, ["sk-from-keychain"])
        XCTAssertEqual(capturedModels, ["claude-sonnet-4-5-20250929"])
    }

    func test_anthropic_missingKeychainAndEnvironment_throwsMissingConfiguration() {
        let keychain = makeKeychainStore()
        let prefs = Preferences(defaults: freshDefaults())
        prefs.rewriteProvider = .anthropic

        let factory = RewriteCompleterFactory(
            keychain: keychain,
            environment: [:],
            makeAnthropic: { _, _ in RecordingCompleter() },
            bedrockBuilder: FakeBedrockBuilder()
        )

        XCTAssertThrowsError(try factory.make(preferences: prefs)) { error in
            XCTAssertEqual(error as? RewriteProviderError, .missingConfiguration)
        }
    }

    func test_anthropic_developmentEnvironmentFallback_usedOnlyWhenKeychainEmpty() throws {
        let keychain = makeKeychainStore()
        let prefs = Preferences(defaults: freshDefaults())
        prefs.rewriteProvider = .anthropic

        var capturedKeys: [String] = []
        let factory = RewriteCompleterFactory(
            keychain: keychain,
            environment: ["ANTHROPIC_API_KEY": "sk-from-env"],
            makeAnthropic: { apiKey, _ in
                capturedKeys.append(apiKey)
                return RecordingCompleter()
            },
            bedrockBuilder: FakeBedrockBuilder()
        )

        _ = try factory.make(preferences: prefs)

        XCTAssertEqual(capturedKeys, ["sk-from-env"])
    }

    func test_anthropic_keychainKeyTakesPrecedenceOverEnvironmentFallback() throws {
        let keychain = makeKeychainStore()
        try keychain.set("sk-from-keychain")
        let prefs = Preferences(defaults: freshDefaults())
        prefs.rewriteProvider = .anthropic

        var capturedKeys: [String] = []
        let factory = RewriteCompleterFactory(
            keychain: keychain,
            environment: ["ANTHROPIC_API_KEY": "sk-from-env"],
            makeAnthropic: { apiKey, _ in
                capturedKeys.append(apiKey)
                return RecordingCompleter()
            },
            bedrockBuilder: FakeBedrockBuilder()
        )

        _ = try factory.make(preferences: prefs)

        XCTAssertEqual(capturedKeys, ["sk-from-keychain"])
    }

    func test_environmentFallback_isAnthropicOnly_neverImplicitlySelectsBedrock() {
        // Even with ANTHROPIC_API_KEY set, an active Bedrock preference must
        // still be routed through the Bedrock builder, and the Anthropic
        // closure must never be invoked.
        let keychain = makeKeychainStore()
        let prefs = Preferences(defaults: freshDefaults())
        prefs.rewriteProvider = .bedrock
        prefs.bedrockRegion = "us-west-2"
        prefs.bedrockModelID = "us.anthropic.claude-opus-4-8"

        let bedrockBuilder = FakeBedrockBuilder()
        var anthropicCallCount = 0
        let factory = RewriteCompleterFactory(
            keychain: keychain,
            environment: ["ANTHROPIC_API_KEY": "sk-from-env"],
            makeAnthropic: { _, _ in
                anthropicCallCount += 1
                return RecordingCompleter()
            },
            bedrockBuilder: bedrockBuilder
        )

        XCTAssertNoThrow(try factory.make(preferences: prefs))
        XCTAssertEqual(anthropicCallCount, 0)
        XCTAssertEqual(bedrockBuilder.configurations.count, 1)
    }

    // MARK: - Bedrock selection

    func test_bedrock_passesExactProfileRegionAndModelToBuilder_withoutReadingAnthropicKeychain() throws {
        let backend = FakeKeychainBackend()
        let keychain = makeKeychainStore(backend: backend)
        // Deliberately do NOT set an Anthropic key.

        let prefs = Preferences(defaults: freshDefaults())
        prefs.rewriteProvider = .bedrock
        prefs.bedrockProfileName = "company-sso"
        prefs.bedrockRegion = "us-west-2"
        prefs.bedrockModelID = "us.anthropic.claude-opus-4-8"

        let bedrockBuilder = FakeBedrockBuilder()
        let factory = RewriteCompleterFactory(
            keychain: keychain,
            environment: [:],
            makeAnthropic: { _, _ in
                XCTFail("Anthropic completer should not be constructed for a Bedrock selection")
                return RecordingCompleter()
            },
            bedrockBuilder: bedrockBuilder
        )

        _ = try factory.make(preferences: prefs)

        XCTAssertEqual(bedrockBuilder.configurations.count, 1)
        XCTAssertEqual(bedrockBuilder.configurations.first?.profileName, "company-sso")
        XCTAssertEqual(bedrockBuilder.configurations.first?.region, "us-west-2")
        XCTAssertEqual(bedrockBuilder.configurations.first?.modelID, "us.anthropic.claude-opus-4-8")
        XCTAssertEqual(backend.copyMatchingCallCount, 0, "Bedrock selection must never read the Anthropic Keychain entry")
    }

    func test_bedrock_missingRegion_throwsMissingConfiguration() {
        let keychain = makeKeychainStore()
        let prefs = Preferences(defaults: freshDefaults())
        prefs.rewriteProvider = .bedrock
        prefs.bedrockRegion = ""

        let factory = RewriteCompleterFactory(
            keychain: keychain,
            environment: [:],
            makeAnthropic: { _, _ in RecordingCompleter() },
            bedrockBuilder: FakeBedrockBuilder()
        )

        XCTAssertThrowsError(try factory.make(preferences: prefs)) { error in
            XCTAssertEqual(error as? RewriteProviderError, .missingConfiguration)
        }
    }

    func test_bedrock_builderThrows_propagatesTheRewriteProviderError() {
        let keychain = makeKeychainStore()
        let prefs = Preferences(defaults: freshDefaults())
        prefs.rewriteProvider = .bedrock
        prefs.bedrockRegion = "us-west-2"
        prefs.bedrockModelID = "us.anthropic.claude-opus-4-8"

        let bedrockBuilder = FakeBedrockBuilder()
        bedrockBuilder.shouldThrow = RewriteProviderError.credentialsUnavailable
        let factory = RewriteCompleterFactory(
            keychain: keychain,
            environment: [:],
            makeAnthropic: { _, _ in RecordingCompleter() },
            bedrockBuilder: bedrockBuilder
        )

        XCTAssertThrowsError(try factory.make(preferences: prefs)) { error in
            XCTAssertEqual(error as? RewriteProviderError, .credentialsUnavailable)
        }
    }

    // MARK: - Unknown/missing provider fallback

    func test_unknownStoredProvider_fallsBackToAnthropicBehavior() throws {
        let keychain = makeKeychainStore()
        try keychain.set("sk-from-keychain")

        let defaults = freshDefaults()
        defaults.set("some-unknown-provider", forKey: "rewriteProvider")
        let prefs = Preferences(defaults: defaults)

        var capturedKeys: [String] = []
        let factory = RewriteCompleterFactory(
            keychain: keychain,
            environment: [:],
            makeAnthropic: { apiKey, _ in
                capturedKeys.append(apiKey)
                return RecordingCompleter()
            },
            bedrockBuilder: FakeBedrockBuilder()
        )

        _ = try factory.make(preferences: prefs)

        XCTAssertEqual(capturedKeys, ["sk-from-keychain"])
    }

    // MARK: - No mutation

    func test_make_neverMutatesPreferences_anthropicPath() throws {
        let keychain = makeKeychainStore()
        try keychain.set("sk-from-keychain")

        let defaults = freshDefaults()
        let prefs = Preferences(defaults: defaults)
        prefs.rewriteProvider = .anthropic
        prefs.anthropicModelName = "claude-haiku-4-5-20251001"

        let before = defaults.dictionaryRepresentation() as NSDictionary

        let factory = RewriteCompleterFactory(
            keychain: keychain,
            environment: [:],
            makeAnthropic: { _, _ in RecordingCompleter() },
            bedrockBuilder: FakeBedrockBuilder()
        )
        _ = try factory.make(preferences: prefs)

        let after = defaults.dictionaryRepresentation() as NSDictionary
        XCTAssertEqual(before, after)
    }

    func test_make_neverMutatesPreferences_bedrockPath() throws {
        let keychain = makeKeychainStore()

        let defaults = freshDefaults()
        let prefs = Preferences(defaults: defaults)
        prefs.rewriteProvider = .bedrock
        prefs.bedrockRegion = "us-west-2"
        prefs.bedrockModelID = "us.anthropic.claude-opus-4-8"

        let before = defaults.dictionaryRepresentation() as NSDictionary

        let factory = RewriteCompleterFactory(
            keychain: keychain,
            environment: [:],
            makeAnthropic: { _, _ in RecordingCompleter() },
            bedrockBuilder: FakeBedrockBuilder()
        )
        _ = try factory.make(preferences: prefs)

        let after = defaults.dictionaryRepresentation() as NSDictionary
        XCTAssertEqual(before, after)
    }
}
