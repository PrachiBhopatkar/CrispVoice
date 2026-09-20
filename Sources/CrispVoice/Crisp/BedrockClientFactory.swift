import BedrockSDKBridge

/// Builds a `TextCompleter` backed by Bedrock. Injectable so callers (e.g.
/// `RewriteConnectionTester`) can substitute a fake in tests.
protocol BedrockClientBuilding {
    func make(configuration: BedrockConfiguration) throws -> TextCompleter
}

/// Thin adapter over the vendor package's `BridgedBedrockClient`. Contains
/// no AWS SDK import: construction is delegated entirely to
/// `vendor/BedrockSDKBridge`.
struct BedrockClientFactory: BedrockClientBuilding {
    func make(configuration: BedrockConfiguration) throws -> TextCompleter {
        let bridgedConfig = BridgedBedrockConfiguration(
            profileName: configuration.profileName,
            region: configuration.region,
            modelID: configuration.modelID
        )
        do {
            let bridged = try BridgedBedrockClient(configuration: bridgedConfig)
            return BedrockClient(bridged: bridged)
        } catch let error as BridgedBedrockError {
            throw RewriteProviderError(bridged: error)
        }
    }
}
