import BedrockSDKBridge

/// Thin adapter over the vendor package's `BridgedBedrockClient`. Contains
/// no AWS SDK import and no SDK-facing logic: all Converse request/response
/// handling and modeled-error mapping live in `vendor/BedrockSDKBridge`.
struct BedrockClient: TextCompleter {
    private let bridged: BridgedBedrockClient

    init(bridged: BridgedBedrockClient) {
        self.bridged = bridged
    }

    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        do {
            return try await bridged.complete(system: system, user: user, maxTokens: maxTokens)
        } catch let error as BridgedBedrockError {
            throw RewriteProviderError(bridged: error)
        }
    }
}
