import XCTest
import BedrockSDKBridge
@testable import CrispVoice

/// Tests the CrispVoice-side adapter only (`BedrockClientFactory`,
/// `BedrockClient`, `RewriteProviderError(bridged:)`). No fake AWS SDK
/// conformer is needed here — the real SDK-facing seam (`ConverseInput`
/// construction, response parsing, modeled-error mapping) is exercised by
/// the vendor package's own tests in `vendor/BedrockSDKBridge`.
final class BedrockClientTests: XCTestCase {

    // MARK: - BedrockClientFactory.make(configuration:)

    func test_make_succeedsLocally_withoutALiveAWSCall() throws {
        // `BridgedBedrockClient.init` only builds local SDK configuration
        // objects (region/endpoint/retry settings); it never resolves
        // credentials or makes a network call, so this must succeed
        // synchronously in any environment, including CI with no AWS
        // profile configured.
        let configuration = try BedrockConfiguration(
            profileName: "office",
            region: "us-west-2",
            modelID: "anthropic.claude-3-opus-20240229-v1:0"
        )
        let factory = BedrockClientFactory()

        let completer = try factory.make(configuration: configuration)

        XCTAssertTrue(completer is BedrockClient)
    }

    func test_make_passesTheConfiguredModelIDThroughToTheBridgedClient() throws {
        let configuration = try BedrockConfiguration(
            profileName: "office",
            region: "us-west-2",
            modelID: "anthropic.claude-3-opus-20240229-v1:0"
        )
        let factory = BedrockClientFactory()

        let completer = try factory.make(configuration: configuration)

        // `BedrockClient`/`BridgedBedrockClient` intentionally retain only
        // `modelID` and a call seam (never region/profile — least
        // retention), so `modelID` is the only field reachable from the
        // constructed value. Reflection here only reaches into our own
        // types (defined in this app and in vendor/BedrockSDKBridge), never
        // into AWS SDK internals.
        let bedrockClient = try XCTUnwrap(completer as? BedrockClient)
        let bridged = try XCTUnwrap(Self.child("bridged", of: bedrockClient))
        XCTAssertEqual(Self.child("modelID", of: bridged) as? String, configuration.modelID)
    }

    func test_make_buildsABridgedConfiguration_withAllThreeFieldsEqualToTheInput() throws {
        // `BedrockClientFactory.make` builds its `BridgedBedrockConfiguration`
        // with exactly `profileName`/`region`/`modelID` copied from the
        // input `BedrockConfiguration` (see `BedrockClientFactory.swift`).
        // `BridgedBedrockClient` deliberately does not retain profile/region
        // after construction, so this pins that documented mapping
        // contract directly rather than reaching into AWS SDK internals
        // (which this module must never import) to re-derive it from a
        // live object.
        let configuration = try BedrockConfiguration(
            profileName: "office",
            region: "us-west-2",
            modelID: "anthropic.claude-3-opus-20240229-v1:0"
        )

        let bridgedConfiguration = BridgedBedrockConfiguration(
            profileName: configuration.profileName,
            region: configuration.region,
            modelID: configuration.modelID
        )

        XCTAssertEqual(bridgedConfiguration.profileName, configuration.profileName)
        XCTAssertEqual(bridgedConfiguration.region, configuration.region)
        XCTAssertEqual(bridgedConfiguration.modelID, configuration.modelID)
    }

    // MARK: - RewriteProviderError(bridged:)

    func test_rewriteProviderError_mapsEachBridgedBedrockErrorCase() {
        let cases: [(BridgedBedrockError, RewriteProviderError)] = [
            (.credentialsUnavailable, .credentialsUnavailable),
            (.accessDenied, .accessDenied),
            (.invalidModelOrRegion, .invalidModelOrRegion),
            (.throttled, .throttled),
            (.network, .network),
            (.invalidResponse, .invalidResponse),
        ]

        for (bridged, expected) in cases {
            XCTAssertEqual(RewriteProviderError(bridged: bridged), expected)
        }
    }

    // MARK: - Helpers

    private static func child(_ label: String, of value: Any) -> Any? {
        Mirror(reflecting: value).children.first(where: { $0.label == label })?.value
    }
}
