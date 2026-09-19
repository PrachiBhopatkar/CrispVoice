import XCTest
import AWSBedrockRuntime
import AWSSDKIdentity
@testable import BedrockSDKBridge

final class BedrockSDKBridgeTests: XCTestCase {
    func testConstructsUnderlyingBedrockRuntimeClient() throws {
        let resolver = ProfileAWSCredentialIdentityResolver(profileName: "office")
        let config = try BedrockRuntimeClient.BedrockRuntimeClientConfig(
            awsCredentialIdentityResolver: resolver,
            region: "us-west-2",
            clientLogMode: .none
        )
        _ = BedrockRuntimeClient(config: config)
    }
}
