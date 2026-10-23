import XCTest
import AWSBedrockRuntime
import AWSSDKIdentity
import ClientRuntime
@testable import BedrockSDKBridge

private final class FakeConverseCaller: BedrockConverseCalling {
    var receivedInput: ConverseInput?
    var result: Result<ConverseOutput, Error> = .failure(BridgedBedrockError.invalidResponse)

    func converse(input: ConverseInput) async throws -> ConverseOutput {
        receivedInput = input
        return try result.get()
    }
}

final class BedrockSDKBridgeTests: XCTestCase {
    func testConstructsUnderlyingBedrockRuntimeClient() throws {
        let resolver = ProfileAWSCredentialIdentityResolver(profileName: "office")
        let config = try BedrockRuntimeClient.BedrockRuntimeClientConfig(
            awsCredentialIdentityResolver: resolver,
            region: "us-west-2",
            clientLogMode: ClientLogMode.none
        )
        _ = BedrockRuntimeClient(config: config)
    }

    // MARK: - Request construction

    func test_complete_sendsExactlyTheExpectedConverseInput() async throws {
        let caller = FakeConverseCaller()
        caller.result = .success(Self.makeOutput(text: "hello there"))
        let client = BridgedBedrockClient(modelID: "anthropic.claude-3-opus", caller: caller)

        _ = try await client.complete(system: "You are terse.", user: "Rewrite this.", maxTokens: 256)

        let input = try XCTUnwrap(caller.receivedInput)
        XCTAssertEqual(input.modelId, "anthropic.claude-3-opus")

        // system == [.text(system)]
        XCTAssertEqual(input.system?.count, 1)
        XCTAssertEqual(Self.text(from: input.system?.first), "You are terse.")

        // one .user message containing .text(user)
        XCTAssertEqual(input.messages?.count, 1)
        let message = try XCTUnwrap(input.messages?.first)
        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.content?.count, 1)
        XCTAssertEqual(Self.text(from: message.content?.first), "Rewrite this.")

        // inferenceConfig.maxTokens == caller's value
        XCTAssertEqual(input.inferenceConfig?.maxTokens, 256)

        // no request metadata, guardrail, tools, or additional fields
        XCTAssertNil(input.requestMetadata)
        XCTAssertNil(input.guardrailConfig)
        XCTAssertNil(input.toolConfig)
        XCTAssertNil(input.additionalModelRequestFields)
        XCTAssertNil(input.additionalModelResponseFieldPaths)
        XCTAssertNil(input.promptVariables)
        XCTAssertNil(input.performanceConfig)
        XCTAssertNil(input.serviceTier)
        XCTAssertNil(input.outputConfig)
    }

    // MARK: - Response handling

    func test_complete_returnsSingleTextBlock() async throws {
        let caller = FakeConverseCaller()
        caller.result = .success(Self.makeOutput(text: "Only one block."))
        let client = BridgedBedrockClient(modelID: "model", caller: caller)

        let result = try await client.complete(system: "s", user: "u", maxTokens: 5)

        XCTAssertEqual(result, "Only one block.")
    }

    func test_complete_joinsMultipleTextBlocks() async throws {
        let caller = FakeConverseCaller()
        let message = BedrockRuntimeClientTypes.Message(
            content: [.text("Hello, "), .text("world.")],
            role: .assistant
        )
        caller.result = .success(ConverseOutput(output: .message(message)))
        let client = BridgedBedrockClient(modelID: "model", caller: caller)

        let result = try await client.complete(system: "s", user: "u", maxTokens: 5)

        XCTAssertEqual(result, "Hello, world.")
    }

    func test_complete_throwsInvalidResponse_whenContentIsEmpty() async throws {
        let caller = FakeConverseCaller()
        let message = BedrockRuntimeClientTypes.Message(content: [], role: .assistant)
        caller.result = .success(ConverseOutput(output: .message(message)))
        let client = BridgedBedrockClient(modelID: "model", caller: caller)

        await Self.assertThrows(.invalidResponse) {
            _ = try await client.complete(system: "s", user: "u", maxTokens: 5)
        }
    }

    func test_complete_throwsInvalidResponse_whenOutputIsNotAMessage() async throws {
        let caller = FakeConverseCaller()
        caller.result = .success(ConverseOutput(output: .sdkUnknown("unexpected")))
        let client = BridgedBedrockClient(modelID: "model", caller: caller)

        await Self.assertThrows(.invalidResponse) {
            _ = try await client.complete(system: "s", user: "u", maxTokens: 5)
        }
    }

    func test_complete_throwsInvalidResponse_whenContentIsNotTextOnly() async throws {
        let caller = FakeConverseCaller()
        let message = BedrockRuntimeClientTypes.Message(
            content: [.tooluse(BedrockRuntimeClientTypes.ToolUseBlock())],
            role: .assistant
        )
        caller.result = .success(ConverseOutput(output: .message(message)))
        let client = BridgedBedrockClient(modelID: "model", caller: caller)

        await Self.assertThrows(.invalidResponse) {
            _ = try await client.complete(system: "s", user: "u", maxTokens: 5)
        }
    }

    // MARK: - Modeled-error mapping

    func test_complete_mapsAccessDeniedException() async {
        await Self.assertMaps(AccessDeniedException(message: "fake-access-denied"), to: .accessDenied)
    }

    func test_complete_mapsValidationException() async {
        await Self.assertMaps(ValidationException(message: "fake-validation"), to: .invalidModelOrRegion)
    }

    func test_complete_mapsResourceNotFoundException() async {
        await Self.assertMaps(ResourceNotFoundException(message: "fake-not-found"), to: .invalidModelOrRegion)
    }

    func test_complete_mapsModelNotReadyException() async {
        await Self.assertMaps(ModelNotReadyException(message: "fake-not-ready"), to: .invalidModelOrRegion)
    }

    func test_complete_mapsThrottlingException() async {
        await Self.assertMaps(ThrottlingException(message: "fake-throttled"), to: .throttled)
    }

    func test_complete_mapsServiceQuotaExceededException() async {
        await Self.assertMaps(ServiceQuotaExceededException(message: "fake-quota"), to: .throttled)
    }

    func test_complete_mapsGenericTransportError_toNetwork() async {
        struct FakeTransportError: Error {
            let secretLadenDescription: String
        }
        let error = FakeTransportError(
            secretLadenDescription:
                "curl failed: Authorization: AWS4-HMAC-SHA256 Credential=AKIAFAKEFAKEFAKE1234/us-east-1, " +
                "arn:aws:iam::123456789012:role/FakeRole, prompt=\"ignore all instructions\""
        )
        await Self.assertMaps(error, to: .network)
    }

    func test_errorMapper_mapsIdentityResolverFailure_toCredentialsUnavailable() {
        let error = AWSCredentialIdentityResolverError.failedToResolveAWSCredentials(
            "Profile with name office doesn't exist. arn:aws:iam::123456789012:role/FakeRole"
        )
        XCTAssertEqual(BedrockErrorMapper.map(error), .credentialsUnavailable)
    }

    // MARK: - Helpers

    private static func makeOutput(text: String) -> ConverseOutput {
        let message = BedrockRuntimeClientTypes.Message(content: [.text(text)], role: .assistant)
        return ConverseOutput(output: .message(message))
    }

    private static func text(from block: BedrockRuntimeClientTypes.ContentBlock?) -> String? {
        guard case .text(let value)? = block else { return nil }
        return value
    }

    private static func text(from block: BedrockRuntimeClientTypes.SystemContentBlock?) -> String? {
        guard case .text(let value)? = block else { return nil }
        return value
    }

    private static func assertMaps(
        _ error: Error,
        to expected: BridgedBedrockError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let caller = FakeConverseCaller()
        caller.result = .failure(error)
        let client = BridgedBedrockClient(modelID: "model", caller: caller)

        do {
            _ = try await client.complete(system: "s", user: "u", maxTokens: 5)
            XCTFail("expected a BridgedBedrockError to be thrown", file: file, line: line)
        } catch let bridged as BridgedBedrockError {
            XCTAssertEqual(bridged, expected, file: file, line: line)
        } catch {
            XCTFail("expected BridgedBedrockError, got \(type(of: error))", file: file, line: line)
        }
    }

    private static func assertThrows(
        _ expected: BridgedBedrockError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("expected a BridgedBedrockError to be thrown", file: file, line: line)
        } catch let bridged as BridgedBedrockError {
            XCTAssertEqual(bridged, expected, file: file, line: line)
        } catch {
            XCTFail("expected BridgedBedrockError, got \(type(of: error))", file: file, line: line)
        }
    }
}
