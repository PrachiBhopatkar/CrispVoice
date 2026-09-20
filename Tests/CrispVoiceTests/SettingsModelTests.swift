import XCTest
@testable import CrispVoice

@MainActor
final class SettingsModelTests: XCTestCase {

    // MARK: - Fakes

    private final class FakeKeychainBackend {
        var storage: [String: Data] = [:]
        /// When set, `add` returns this status instead of succeeding —
        /// used to simulate a genuine Keychain write failure.
        var forcedAddStatus: OSStatus?

        func add(query: CFDictionary, _: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
            if let forcedAddStatus { return forcedAddStatus }
            let dict = query as NSDictionary
            guard
                let service = dict[kSecAttrService as String] as? String,
                let account = dict[kSecAttrAccount as String] as? String,
                let data = dict[kSecValueData as String] as? Data
            else {
                return errSecParam
            }
            storage[key(service: service, account: account)] = data
            return errSecSuccess
        }

        func copyMatching(query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
            let dict = query as NSDictionary
            guard
                let service = dict[kSecAttrService as String] as? String,
                let account = dict[kSecAttrAccount as String] as? String
            else {
                return errSecParam
            }
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
            else {
                return errSecParam
            }
            let key = key(service: service, account: account)
            if storage.removeValue(forKey: key) == nil {
                return errSecItemNotFound
            }
            return errSecSuccess
        }

        private func key(service: String, account: String) -> String {
            "\(service)::\(account)"
        }
    }

    private final class RecordingCompleter: TextCompleter {
        private(set) var systems: [String] = []
        private(set) var users: [String] = []
        private(set) var maxTokensSeen: [Int] = []
        var result: Result<String, Error> = .success("OK")

        func complete(system: String, user: String, maxTokens: Int) async throws -> String {
            systems.append(system)
            users.append(user)
            maxTokensSeen.append(maxTokens)
            return try result.get()
        }
    }

    private final class FakeBedrockBuilder: BedrockClientBuilding {
        private(set) var configurations: [BedrockConfiguration] = []
        let completer: TextCompleter

        init(completer: TextCompleter) {
            self.completer = completer
        }

        func make(configuration: BedrockConfiguration) throws -> TextCompleter {
            configurations.append(configuration)
            return completer
        }
    }

    private final class FakeConnectionTester: RewriteConnectionTesting {
        private(set) var anthropicCalls: [(apiKey: String, model: String)] = []
        private(set) var bedrockCalls: [BedrockConfiguration] = []
        var anthropicResult: Result<Void, Error> = .success(())
        var bedrockResult: Result<Void, Error> = .success(())

        func testAnthropic(apiKey: String, model: String) async throws {
            anthropicCalls.append((apiKey, model))
            try anthropicResult.get()
        }

        func testBedrock(configuration: BedrockConfiguration) async throws {
            bedrockCalls.append(configuration)
            try bedrockResult.get()
        }
    }

    // MARK: - Helpers

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "com.crispvoice.tests.settingsmodel.\(UUID().uuidString)")!
    }

    private func makeKeychainStore(backend: FakeKeychainBackend = FakeKeychainBackend()) -> KeychainStore {
        let service = "com.crispvoice.tests.settingsmodel.\(UUID().uuidString)"
        let client = KeychainStore.SecurityClient(
            add: backend.add(query:_:),
            copyMatching: backend.copyMatching(query:result:),
            delete: backend.delete(query:)
        )
        return KeychainStore(service: service, securityClient: client)
    }

    private func makeModel(
        defaults: UserDefaults,
        keychain: KeychainStore,
        connectionTester: RewriteConnectionTesting = FakeConnectionTester()
    ) -> SettingsModel {
        SettingsModel(
            keychain: keychain,
            prefs: Preferences(defaults: defaults),
            connectionTester: connectionTester
        )
    }

    // MARK: - Initialization loads both provider drafts and the active provider

    func test_init_loadsBothProviderDraftsAndPersistedActiveProvider() throws {
        let defaults = freshDefaults()
        let prefs = Preferences(defaults: defaults)
        prefs.rewriteProvider = .bedrock
        prefs.anthropicModelName = "claude-sonnet-4-5-20250929"
        prefs.bedrockProfileName = "work"
        prefs.bedrockRegion = "us-west-2"
        prefs.bedrockModelID = "us.anthropic.claude-opus-4-8"
        prefs.variantCount = 4

        let keychain = makeKeychainStore()
        try keychain.set("sk-existing")

        let model = makeModel(defaults: defaults, keychain: keychain)

        XCTAssertEqual(model.selectedProvider, .bedrock)
        XCTAssertEqual(model.anthropicAPIKey, "sk-existing")
        XCTAssertEqual(model.anthropicModelName, "claude-sonnet-4-5-20250929")
        XCTAssertEqual(model.bedrockProfileName, "work")
        XCTAssertEqual(model.bedrockRegion, "us-west-2")
        XCTAssertEqual(model.bedrockModelOption, .opus48US)
        XCTAssertEqual(model.variantCount, 4)
    }

    // MARK: - Editing drafts never mutates UserDefaults/Keychain

    func test_editingDraftFields_doesNotMutateUserDefaultsOrKeychain() {
        let defaults = freshDefaults()
        let keychain = makeKeychainStore()
        let model = makeModel(defaults: defaults, keychain: keychain)

        model.selectedProvider = .bedrock
        model.anthropicAPIKey = "sk-new-draft"
        model.anthropicModelName = "claude-sonnet-4-5-20250929"
        model.bedrockProfileName = "new-profile"
        model.bedrockRegion = "eu-central-1"
        model.bedrockModelOption = .custom("company.model")
        model.bedrockCustomModelID = "company.model"
        model.variantCount = 5

        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.rewriteProvider, .anthropic)
        XCTAssertEqual(reloaded.anthropicModelName, "claude-haiku-4-5-20251001")
        XCTAssertEqual(reloaded.bedrockProfileName, "default")
        XCTAssertEqual(reloaded.bedrockRegion, "")
        XCTAssertEqual(reloaded.variantCount, 3)
        XCTAssertNil(keychain.get())
    }

    // MARK: - Close/cancel discards drafts

    func test_closeWithoutSave_thenNewModel_discardsDrafts() {
        let defaults = freshDefaults()
        let keychain = makeKeychainStore()

        let model = makeModel(defaults: defaults, keychain: keychain)
        model.anthropicAPIKey = "sk-throwaway"
        model.selectedProvider = .bedrock
        model.bedrockRegion = "throwaway-region"
        // "Closing" Settings without Save simply discards this instance —
        // the next time Settings opens, a brand new model is created.

        let reopened = makeModel(defaults: defaults, keychain: keychain)

        XCTAssertEqual(reopened.selectedProvider, .anthropic)
        XCTAssertEqual(reopened.anthropicAPIKey, "")
        XCTAssertEqual(reopened.bedrockRegion, "")
    }

    // MARK: - Test Connection

    func test_testConnection_anthropic_usesDraftKeyAndModel_withTokenLimit5_withoutPersisting() async {
        let defaults = freshDefaults()
        let keychain = makeKeychainStore()
        let tester = FakeConnectionTester()
        let model = makeModel(defaults: defaults, keychain: keychain, connectionTester: tester)
        model.selectedProvider = .anthropic
        model.anthropicAPIKey = "  sk-draft-key  "
        model.anthropicModelName = "claude-sonnet-4-5-20250929"

        await model.testConnection()

        XCTAssertEqual(tester.anthropicCalls.count, 1)
        XCTAssertEqual(tester.anthropicCalls.first?.apiKey, "sk-draft-key")
        XCTAssertEqual(tester.anthropicCalls.first?.model, "claude-sonnet-4-5-20250929")
        XCTAssertTrue(model.validationMessage.contains("succeeded"))
        XCTAssertNil(keychain.get())
        XCTAssertEqual(Preferences(defaults: defaults).anthropicModelName, "claude-haiku-4-5-20251001")
    }

    func test_testConnection_bedrock_normalizesBlankProfileToDefault_usesDraftRegionAndModel_withTokenLimit5_withoutPersisting() async {
        let defaults = freshDefaults()
        let keychain = makeKeychainStore()
        let tester = FakeConnectionTester()
        let model = makeModel(defaults: defaults, keychain: keychain, connectionTester: tester)
        model.selectedProvider = .bedrock
        model.bedrockProfileName = "   "
        model.bedrockRegion = "us-west-2"
        model.bedrockModelOption = .custom("company.custom-model")
        model.bedrockCustomModelID = "company.custom-model"

        await model.testConnection()

        XCTAssertEqual(tester.bedrockCalls.count, 1)
        XCTAssertEqual(tester.bedrockCalls.first?.profileName, "default")
        XCTAssertEqual(tester.bedrockCalls.first?.region, "us-west-2")
        XCTAssertEqual(tester.bedrockCalls.first?.modelID, "company.custom-model")
        XCTAssertTrue(model.validationMessage.contains("succeeded"))
        XCTAssertEqual(Preferences(defaults: defaults).bedrockRegion, "")
        XCTAssertEqual(Preferences(defaults: defaults).bedrockProfileName, "default")
    }

    func test_testConnection_anyNonEmptyResponse_succeeds_forBothProviders() async throws {
        let defaults = freshDefaults()
        let keychain = makeKeychainStore()
        let tester = FakeConnectionTester()
        let model = makeModel(defaults: defaults, keychain: keychain, connectionTester: tester)
        model.anthropicAPIKey = "sk-any"
        model.bedrockRegion = "us-west-2"

        await model.testConnection() // Anthropic active by default
        XCTAssertTrue(model.validationMessage.contains("succeeded"))

        model.selectedProvider = .bedrock
        await model.testConnection()
        XCTAssertTrue(model.validationMessage.contains("succeeded"))
    }

    func test_testConnection_failure_keepsPersistedProviderSettingsAndKeychainUnchanged() async throws {
        let defaults = freshDefaults()
        let prefs = Preferences(defaults: defaults)
        prefs.rewriteProvider = .anthropic
        prefs.anthropicModelName = "claude-haiku-4-5-20251001"

        let keychain = makeKeychainStore()
        try keychain.set("sk-persisted")

        let tester = FakeConnectionTester()
        tester.anthropicResult = .failure(RewriteProviderError.network)

        let model = makeModel(defaults: defaults, keychain: keychain, connectionTester: tester)
        model.anthropicAPIKey = "sk-different-draft"

        await model.testConnection()

        XCTAssertFalse(model.validationMessage.isEmpty)
        XCTAssertEqual(keychain.get(), "sk-persisted")
        XCTAssertEqual(Preferences(defaults: defaults).rewriteProvider, .anthropic)
        XCTAssertEqual(Preferences(defaults: defaults).anthropicModelName, "claude-haiku-4-5-20251001")
    }

    // MARK: - Save validation

    func test_save_rejectsMissingAnthropicKey_whenActivatingAnthropic() {
        let defaults = freshDefaults()
        let keychain = makeKeychainStore()
        let model = makeModel(defaults: defaults, keychain: keychain)
        model.selectedProvider = .anthropic
        model.anthropicAPIKey = "   "

        model.save()

        XCTAssertFalse(model.validationMessage.isEmpty)
        XCTAssertNil(keychain.get())
        XCTAssertEqual(Preferences(defaults: defaults).rewriteProvider, .anthropic)
    }

    func test_save_rejectsBlankBedrockRegionOrModel_whenActivatingBedrock() {
        let defaults = freshDefaults()
        let keychain = makeKeychainStore()
        let model = makeModel(defaults: defaults, keychain: keychain)
        model.selectedProvider = .bedrock
        model.bedrockRegion = ""
        model.bedrockModelOption = .opus48US

        model.save()

        XCTAssertFalse(model.validationMessage.isEmpty)
        XCTAssertEqual(Preferences(defaults: defaults).rewriteProvider, .anthropic)
        XCTAssertEqual(Preferences(defaults: defaults).bedrockRegion, "")

        model.bedrockRegion = "us-west-2"
        model.bedrockModelOption = .custom("")
        model.bedrockCustomModelID = "   "

        model.save()

        XCTAssertFalse(model.validationMessage.isEmpty)
        XCTAssertEqual(Preferences(defaults: defaults).rewriteProvider, .anthropic)
    }

    // MARK: - Successful Save

    func test_save_success_persistsBothProvidersDraftsAndVariantCount_updatesKeychain_thenActivatesSelectedProvider() {
        let defaults = freshDefaults()
        let keychain = makeKeychainStore()
        let model = makeModel(defaults: defaults, keychain: keychain)

        model.selectedProvider = .bedrock
        model.anthropicAPIKey = "sk-both-saved"
        model.anthropicModelName = "claude-sonnet-4-5-20250929"
        model.bedrockProfileName = "office"
        model.bedrockRegion = "us-west-2"
        model.bedrockModelOption = .opus48US
        model.variantCount = 5

        model.save()

        XCTAssertEqual(keychain.get(), "sk-both-saved")
        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.rewriteProvider, .bedrock)
        XCTAssertEqual(reloaded.anthropicModelName, "claude-sonnet-4-5-20250929")
        XCTAssertEqual(reloaded.bedrockProfileName, "office")
        XCTAssertEqual(reloaded.bedrockRegion, "us-west-2")
        XCTAssertEqual(reloaded.bedrockModelID, "us.anthropic.claude-opus-4-8")
        XCTAssertEqual(reloaded.variantCount, 5)
    }

    func test_save_allowedWithoutPriorSuccessfulNetworkTest() {
        let defaults = freshDefaults()
        let keychain = makeKeychainStore()
        let model = makeModel(defaults: defaults, keychain: keychain)
        model.anthropicAPIKey = "sk-no-test-needed"
        model.validationMessage = "❌ Connection failed previously."

        model.save()

        XCTAssertEqual(keychain.get(), "sk-no-test-needed")
        XCTAssertEqual(Preferences(defaults: defaults).rewriteProvider, .anthropic)
        XCTAssertTrue(model.validationMessage.contains("saved"))
    }

    func test_save_postsContentFreeNotification_withExactNameObjectNilUserInfoNil() {
        let defaults = freshDefaults()
        let keychain = makeKeychainStore()
        let model = makeModel(defaults: defaults, keychain: keychain)
        model.anthropicAPIKey = "sk-notify"

        let expectation = expectation(description: "notification posted")
        var received: Notification?
        let observer = NotificationCenter.default.addObserver(
            forName: .crispVoiceRewriteConfigurationDidChange,
            object: nil,
            queue: nil
        ) { notification in
            received = notification
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        model.save()

        wait(for: [expectation], timeout: 1)

        XCTAssertNotNil(received)
        XCTAssertNil(received?.object)
        XCTAssertNil(received?.userInfo)
    }

    // MARK: - Switching drafts never deletes the other provider's data

    func test_switchingDrafts_neverDeletesOtherProvidersData() {
        let defaults = freshDefaults()
        let prefs = Preferences(defaults: defaults)
        prefs.rewriteProvider = .anthropic
        prefs.bedrockProfileName = "existing-bedrock-profile"
        prefs.bedrockRegion = "us-east-1"
        prefs.bedrockModelID = "us.anthropic.claude-opus-4-8"

        let keychain = makeKeychainStore()
        try? keychain.set("sk-existing")

        let model = makeModel(defaults: defaults, keychain: keychain)
        model.selectedProvider = .bedrock
        model.selectedProvider = .anthropic
        model.selectedProvider = .bedrock

        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.bedrockProfileName, "existing-bedrock-profile")
        XCTAssertEqual(reloaded.bedrockRegion, "us-east-1")
        XCTAssertEqual(reloaded.bedrockModelID, "us.anthropic.claude-opus-4-8")
        XCTAssertEqual(keychain.get(), "sk-existing")
    }

    /// Exercises the real reversibility path end-to-end: provider A is
    /// configured and actually saved, the draft is switched to provider B
    /// with a valid configuration, and `save()` is called again. Unlike
    /// `test_switchingDrafts_neverDeletesOtherProvidersData` (which only
    /// mutates the in-memory draft and never calls `save()`), this proves
    /// the on-disk guarantee for the path a user actually takes: activating
    /// Bedrock must not touch the previously-saved Anthropic Keychain entry
    /// or its `UserDefaults` values, and vice versa (design section 7:
    /// "Switching to Bedrock does not delete the stored Anthropic key.
    /// Switching back to Anthropic does not delete Bedrock configuration.").
    func test_saveAfterSwitchingProvider_preservesThePreviouslyActiveProvidersPersistedData() {
        let defaults = freshDefaults()
        let keychain = makeKeychainStore()

        // Step 1: configure and actually save Anthropic as the active provider.
        let firstModel = makeModel(defaults: defaults, keychain: keychain)
        firstModel.selectedProvider = .anthropic
        firstModel.anthropicAPIKey = "sk-anthropic-persisted"
        firstModel.anthropicModelName = "claude-sonnet-4-5-20250929"
        firstModel.save()

        XCTAssertEqual(keychain.get(), "sk-anthropic-persisted")
        XCTAssertEqual(Preferences(defaults: defaults).rewriteProvider, .anthropic)

        // Step 2: open a fresh model (as Settings reopening would), switch
        // the draft to Bedrock with a valid configuration, and save.
        let secondModel = makeModel(defaults: defaults, keychain: keychain)
        secondModel.selectedProvider = .bedrock
        secondModel.bedrockProfileName = "office"
        secondModel.bedrockRegion = "us-west-2"
        secondModel.bedrockModelOption = .opus48US
        secondModel.save()

        XCTAssertEqual(Preferences(defaults: defaults).rewriteProvider, .bedrock)

        // The previously-active Anthropic provider's persisted data must
        // still be intact even though it is no longer the active provider.
        XCTAssertEqual(keychain.get(), "sk-anthropic-persisted")
        XCTAssertEqual(Preferences(defaults: defaults).anthropicModelName, "claude-sonnet-4-5-20250929")
    }

    /// Symmetric case: Bedrock configured and saved first, then the draft
    /// switches to Anthropic and saves — Bedrock's persisted configuration
    /// must survive.
    func test_saveAfterSwitchingProvider_symmetricCase_bedrockThenAnthropic_preservesBedrocksPersistedData() {
        let defaults = freshDefaults()
        let keychain = makeKeychainStore()

        let firstModel = makeModel(defaults: defaults, keychain: keychain)
        firstModel.selectedProvider = .bedrock
        firstModel.bedrockProfileName = "office"
        firstModel.bedrockRegion = "us-west-2"
        firstModel.bedrockModelOption = .custom("company.custom-model")
        firstModel.bedrockCustomModelID = "company.custom-model"
        firstModel.save()

        XCTAssertEqual(Preferences(defaults: defaults).rewriteProvider, .bedrock)
        XCTAssertEqual(Preferences(defaults: defaults).bedrockProfileName, "office")
        XCTAssertEqual(Preferences(defaults: defaults).bedrockRegion, "us-west-2")
        XCTAssertEqual(Preferences(defaults: defaults).bedrockModelID, "company.custom-model")

        let secondModel = makeModel(defaults: defaults, keychain: keychain)
        secondModel.selectedProvider = .anthropic
        secondModel.anthropicAPIKey = "sk-anthropic-now-active"
        secondModel.anthropicModelName = "claude-haiku-4-5-20251001"
        secondModel.save()

        XCTAssertEqual(Preferences(defaults: defaults).rewriteProvider, .anthropic)

        // The previously-active Bedrock provider's persisted configuration
        // must still be intact even though it is no longer active.
        XCTAssertEqual(Preferences(defaults: defaults).bedrockProfileName, "office")
        XCTAssertEqual(Preferences(defaults: defaults).bedrockRegion, "us-west-2")
        XCTAssertEqual(Preferences(defaults: defaults).bedrockModelID, "company.custom-model")
    }

    // MARK: - Transactional Save: Keychain write ordering / partial failure

    func test_save_keychainThrows_leavesPreferencesAndActiveProviderUnchanged() {
        let defaults = freshDefaults()
        let prefs = Preferences(defaults: defaults)
        prefs.rewriteProvider = .anthropic
        prefs.anthropicModelName = "claude-haiku-4-5-20251001"

        let backend = FakeKeychainBackend()
        let keychain = makeKeychainStore(backend: backend)
        let model = makeModel(defaults: defaults, keychain: keychain)
        model.selectedProvider = .bedrock
        model.anthropicAPIKey = "sk-should-not-persist"
        model.bedrockRegion = "us-west-2"
        model.bedrockModelOption = .opus48US
        model.variantCount = 5

        backend.forcedAddStatus = errSecParam // force the Keychain write to fail

        model.save()

        XCTAssertFalse(model.validationMessage.isEmpty)
        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.rewriteProvider, .anthropic, "active provider must not change when Keychain throws")
        XCTAssertEqual(reloaded.bedrockRegion, "", "no UserDefaults value may change when Keychain throws")
        XCTAssertEqual(reloaded.variantCount, 3)
        XCTAssertNil(keychain.get())
    }

    // MARK: - RewriteConnectionTester (tested directly, independent of SettingsModel)

    func test_rewriteConnectionTester_testAnthropic_sendsExactProbe_andUsesDraftInputs() async throws {
        let completer = RecordingCompleter()
        var capturedArgs: (apiKey: String, model: String)?
        let tester = RewriteConnectionTester(
            makeAnthropic: { apiKey, model in
                capturedArgs = (apiKey, model)
                return completer
            },
            bedrockBuilder: FakeBedrockBuilder(completer: completer)
        )

        try await tester.testAnthropic(apiKey: "sk-probe", model: "claude-sonnet-4-5-20250929")

        XCTAssertEqual(capturedArgs?.apiKey, "sk-probe")
        XCTAssertEqual(capturedArgs?.model, "claude-sonnet-4-5-20250929")
        XCTAssertEqual(completer.systems, ["Reply with OK."])
        XCTAssertEqual(completer.users, ["ping"])
        XCTAssertEqual(completer.maxTokensSeen, [5])
    }

    func test_rewriteConnectionTester_testAnthropic_anyNonEmptyResponse_succeeds() async throws {
        let completer = RecordingCompleter()
        completer.result = .success("Sure thing, absolutely.")
        let tester = RewriteConnectionTester(
            makeAnthropic: { _, _ in completer },
            bedrockBuilder: FakeBedrockBuilder(completer: completer)
        )

        try await tester.testAnthropic(apiKey: "k", model: "m")
    }

    func test_rewriteConnectionTester_testAnthropic_emptyResponse_throwsInvalidResponse() async {
        let completer = RecordingCompleter()
        completer.result = .success("   ")
        let tester = RewriteConnectionTester(
            makeAnthropic: { _, _ in completer },
            bedrockBuilder: FakeBedrockBuilder(completer: completer)
        )

        do {
            try await tester.testAnthropic(apiKey: "k", model: "m")
            XCTFail("expected invalidResponse")
        } catch {
            XCTAssertEqual(error as? RewriteProviderError, .invalidResponse)
        }
    }

    func test_rewriteConnectionTester_testBedrock_sendsExactProbe_andUsesDraftConfiguration() async throws {
        let completer = RecordingCompleter()
        let builder = FakeBedrockBuilder(completer: completer)
        let tester = RewriteConnectionTester(
            makeAnthropic: { _, _ in completer },
            bedrockBuilder: builder
        )
        let configuration = try BedrockConfiguration(
            profileName: "office",
            region: "us-west-2",
            modelID: "us.anthropic.claude-opus-4-8"
        )

        try await tester.testBedrock(configuration: configuration)

        XCTAssertEqual(builder.configurations, [configuration])
        XCTAssertEqual(completer.systems, ["Reply with OK."])
        XCTAssertEqual(completer.users, ["ping"])
        XCTAssertEqual(completer.maxTokensSeen, [5])
    }

    func test_rewriteConnectionTester_testBedrock_anyNonEmptyResponse_succeeds() async throws {
        let completer = RecordingCompleter()
        completer.result = .success("looks good")
        let builder = FakeBedrockBuilder(completer: completer)
        let tester = RewriteConnectionTester(makeAnthropic: { _, _ in completer }, bedrockBuilder: builder)
        let configuration = try BedrockConfiguration(
            profileName: "office",
            region: "us-west-2",
            modelID: "us.anthropic.claude-opus-4-8"
        )

        try await tester.testBedrock(configuration: configuration)
    }

    func test_rewriteConnectionTester_testBedrock_emptyResponse_throwsInvalidResponse() async throws {
        let completer = RecordingCompleter()
        completer.result = .success("")
        let builder = FakeBedrockBuilder(completer: completer)
        let tester = RewriteConnectionTester(makeAnthropic: { _, _ in completer }, bedrockBuilder: builder)
        let configuration = try BedrockConfiguration(
            profileName: "office",
            region: "us-west-2",
            modelID: "us.anthropic.claude-opus-4-8"
        )

        do {
            try await tester.testBedrock(configuration: configuration)
            XCTFail("expected invalidResponse")
        } catch {
            XCTAssertEqual(error as? RewriteProviderError, .invalidResponse)
        }
    }
}
