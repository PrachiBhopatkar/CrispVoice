import Foundation
internal import AWSBedrockRuntime
internal import AWSSDKIdentity
internal import ClientRuntime

/// The validated fields needed to build a `BridgedBedrockClient`. This type
/// carries no secrets: the profile name identifies which local AWS
/// credential profile to use, never a raw credential value.
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

/// The closed, privacy-safe error surface raised by this package. No case
/// carries an associated raw/source error value or text: only the stable
/// classification is ever exposed to callers. `@frozen` because this set is
/// fixed by design (mirrors `RewriteProviderError`'s six mapped cases);
/// adding a case is a deliberate, coordinated change to both sides, not
/// something callers must defensively handle with `@unknown default`.
@frozen
public enum BridgedBedrockError: Error, Equatable {
    case credentialsUnavailable
    case accessDenied
    case invalidModelOrRegion
    case throttled
    case network
    case invalidResponse
}

/// A narrow seam over `BedrockRuntimeClient.converse(input:)` so tests can
/// substitute a fake conformer instead of making a live AWS call.
protocol BedrockConverseCalling {
    func converse(input: ConverseInput) async throws -> ConverseOutput
}

extension BedrockRuntimeClient: BedrockConverseCalling {}

/// A thin, privacy-boundary client over the AWS Bedrock Runtime Converse
/// API. Stores only the opaque model identifier and a `BedrockConverseCalling`
/// seam; never retains configuration, credentials, or raw SDK errors beyond
/// what is required to make the next call.
public struct BridgedBedrockClient {
    private let modelID: String
    private let caller: BedrockConverseCalling

    /// Test/internal seam: inject a fake `BedrockConverseCalling` conformer.
    init(modelID: String, caller: BedrockConverseCalling) {
        self.modelID = modelID
        self.caller = caller
    }

    /// Builds the real AWS-backed client. SDK HTTP/body logging is
    /// explicitly disabled (`clientLogMode: .none`); credential refresh is
    /// owned by the SDK's resolver/client, never re-triggered per rewrite.
    public init(configuration: BridgedBedrockConfiguration) throws {
        do {
            let resolver = ProfileAWSCredentialIdentityResolver(profileName: configuration.profileName)
            let config = try BedrockRuntimeClient.BedrockRuntimeClientConfig(
                awsCredentialIdentityResolver: resolver,
                region: configuration.region,
                // Explicitly typed (not bare `.none`) to avoid resolving to
                // `Optional<ClientLogMode>.none` (nil, which would fall back
                // to the SDK's own default log mode instead of disabling
                // HTTP/body logging).
                clientLogMode: ClientRuntime.ClientLogMode.none
            )
            let client = BedrockRuntimeClient(config: config)
            self.init(modelID: configuration.modelID, caller: client)
        } catch {
            throw BedrockErrorMapper.map(error)
        }
    }

    public func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        let input = ConverseInput(
            inferenceConfig: BedrockRuntimeClientTypes.InferenceConfiguration(maxTokens: maxTokens),
            messages: [
                BedrockRuntimeClientTypes.Message(content: [.text(user)], role: .user)
            ],
            modelId: modelID,
            system: [.text(system)]
        )

        let output: ConverseOutput
        do {
            output = try await caller.converse(input: input)
        } catch let error as BridgedBedrockError {
            throw error
        } catch {
            throw BedrockErrorMapper.map(error)
        }

        return try Self.extractText(from: output)
    }

    /// Extracts and concatenates only `.text` content blocks from the
    /// model's message. Trims solely to decide whether the result is
    /// empty; returns the original, non-empty text otherwise.
    private static func extractText(from output: ConverseOutput) throws -> String {
        guard
            let converseOutput = output.output,
            case .message(let message) = converseOutput,
            let blocks = message.content
        else {
            throw BridgedBedrockError.invalidResponse
        }

        var text = ""
        for block in blocks {
            if case .text(let value) = block {
                text += value
            }
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgedBedrockError.invalidResponse
        }

        return text
    }
}
