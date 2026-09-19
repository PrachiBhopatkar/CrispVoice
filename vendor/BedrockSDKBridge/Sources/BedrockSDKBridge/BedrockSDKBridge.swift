public struct BridgedBedrockConfiguration {
    public let profileName: String
    public let region: String
    public let modelID: String
    public init(profileName: String, region: String, modelID: String) {
        self.profileName = profileName
        self.region = region
        self.modelID = modelID
    }
}

public enum BridgedBedrockError: Error, Equatable {
    case credentialsUnavailable
    case accessDenied
    case invalidModelOrRegion
    case throttled
    case network
    case invalidResponse
}

public struct BridgedBedrockClient {
    public init(configuration: BridgedBedrockConfiguration) throws {
        fatalError("not implemented")
    }
    public func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        fatalError("not implemented")
    }
}
