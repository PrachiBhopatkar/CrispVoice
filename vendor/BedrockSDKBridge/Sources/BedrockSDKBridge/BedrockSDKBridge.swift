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
    /// Always resolves the standard `~/.aws/config`/`~/.aws/credentials`
    /// files (see the internal `configFilePath`/`credentialsFilePath`
    /// overload below, used only by tests).
    public init(configuration: BridgedBedrockConfiguration) throws {
        try self.init(configuration: configuration, configFilePath: nil, credentialsFilePath: nil)
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

extension BridgedBedrockClient {
    /// Test-only seam: explicitly overrides the AWS config and shared
    /// credentials file paths passed to `ProfileAWSCredentialIdentityResolver`,
    /// so contract tests can point the SDK's own profile resolver at a
    /// private, temporary AWS profile instead of the real
    /// `~/.aws/config`/`~/.aws/credentials`. `profileName` is always
    /// passed explicitly; nothing here reads `AWS_PROFILE`.
    ///
    /// The production `public init(configuration:)` calls this with both
    /// arguments `nil`, which the SDK resolves to the standard files --
    /// this overload changes only where the resolver looks, never the
    /// production default.
    init(configuration: BridgedBedrockConfiguration, configFilePath: String?, credentialsFilePath: String?) throws {
        do {
            let resolver = ProfileAWSCredentialIdentityResolver(
                profileName: configuration.profileName,
                configFilePath: configFilePath,
                credentialsFilePath: credentialsFilePath
            )
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
}
