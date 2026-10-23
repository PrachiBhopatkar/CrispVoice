import XCTest
import AWSSDKIdentity
@testable import BedrockSDKBridge

/// Proves that AWS's own `credential_process` mechanism -- a
/// company-configured executable that emits temporary AWS credentials as
/// JSON on stdout -- resolves and refreshes correctly through the AWS SDK
/// for Swift's own `ProfileAWSCredentialIdentityResolver`, when that
/// resolver is pointed explicitly at a private, temporary AWS config and
/// credentials file.
///
/// Trust boundary: every test below exercises `ProfileAWSCredentialIdentityResolver`,
/// an AWS SDK type. No test spawns a process itself, parses process
/// output itself, or otherwise re-implements `credential_process` handling;
/// that is exactly the app-authored process execution this suite must
/// NOT contain (design 5.3, 13). CrispVoice application code never
/// invokes a shell or a credential process directly, in this package or
/// under `Sources/CrispVoice/`.
///
/// Every fixture path used below is:
///   - copied into a private (0700) temporary directory with no spaces,
///     so a `credential_process` value never needs shell quoting;
///   - never `~/.aws/config`, `~/.aws/credentials`, or `AWS_PROFILE`;
///   - referenced only with an explicit `profileName`, never a login shell.
final class CredentialProviderContractTests: XCTestCase {
    // MARK: - Fixture environment

    /// A private, temporary AWS config/credentials pair plus a copy of the
    /// fixture script, all rooted in one no-space temporary directory that
    /// is removed after each test.
    private struct FixtureEnvironment {
        let root: URL
        let configFilePath: String
        let credentialsFilePath: String
        let stateFilePath: String
        let profileName: String

        func resolver() -> ProfileAWSCredentialIdentityResolver {
            ProfileAWSCredentialIdentityResolver(
                profileName: profileName,
                configFilePath: configFilePath,
                credentialsFilePath: credentialsFilePath
            )
        }

        func bridgedConfiguration(modelID: String = "fixture.test-model-id") -> BridgedBedrockConfiguration {
            BridgedBedrockConfiguration(
                profileName: profileName,
                region: "us-west-2",
                modelID: modelID
            )
        }

        func makeBridgedClient() throws -> BridgedBedrockClient {
            try BridgedBedrockClient(
                configuration: bridgedConfiguration(),
                configFilePath: configFilePath,
                credentialsFilePath: credentialsFilePath
            )
        }
    }

    private var environmentsToClean: [URL] = []

    override func tearDown() {
        for root in environmentsToClean {
            try? FileManager.default.removeItem(at: root)
        }
        environmentsToClean = []
        super.tearDown()
    }

    /// Builds a private temporary directory (no spaces in its path),
    /// copies the checked-in fixture script into it as an executable with
    /// private permissions, and writes a throwaway AWS config naming one
    /// profile whose `credential_process` invokes that fixture in `mode`.
    /// The credentials file is written but left empty: this profile must
    /// resolve entirely via `credential_process`, never shared static
    /// credentials.
    private func makeFixtureEnvironment(mode: String, function: StaticString = #function) throws -> FixtureEnvironment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("crispvoice-credproc-\(UUID().uuidString)", isDirectory: true)
        XCTAssertFalse(root.path.contains(" "), "fixture root must be a no-space path: \(root.path)")

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        environmentsToClean.append(root)

        let sourceFixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/credential-process-fixture.sh")
        let fixtureCopy = root.appendingPathComponent("credential-process-fixture.sh")
        try FileManager.default.copyItem(at: sourceFixture, to: fixtureCopy)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixtureCopy.path)

        let stateFile = root.appendingPathComponent("invocation-count.state")
        let credentialsFile = root.appendingPathComponent("credentials")
        FileManager.default.createFile(atPath: credentialsFile.path, contents: Data(), attributes: [.posixPermissions: 0o600])

        let profileName = "crispvoice-fixture-profile"
        let configFile = root.appendingPathComponent("config")
        let configContents = """
        [profile \(profileName)]
        credential_process = \(fixtureCopy.path) \(mode) \(stateFile.path)

        """
        try configContents.write(to: configFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFile.path)

        for path in [fixtureCopy.path, stateFile.path, credentialsFile.path, configFile.path, root.path] {
            XCTAssertTrue(path.hasPrefix("/"), "fixture path must be absolute: \(path)")
            XCTAssertFalse(path.contains(" "), "fixture path must contain no spaces: \(path)")
        }

        return FixtureEnvironment(
            root: root,
            configFilePath: configFile.path,
            credentialsFilePath: credentialsFile.path,
            stateFilePath: stateFile.path,
            profileName: profileName
        )
    }

    // MARK: - 1. Named-profile resolution succeeds, no AWS_PROFILE, no login shell

    func test_resolvesNamedProfile_viaCredentialProcess_withNoAWSProfileEnvOrLoginShell() async throws {
        let env = try makeFixtureEnvironment(mode: "success")

        // The profile name is passed explicitly to the resolver; nothing
        // here reads or requires `AWS_PROFILE`, and nothing spawns a login
        // shell (the resolver's own subprocess call is the SDK's, not
        // ours -- see the trust-boundary note above).
        let identity = try await env.resolver().getIdentity(identityProperties: nil)

        XCTAssertEqual(identity.accessKey, "ASIAFIXTURETEST0001")
        XCTAssertEqual(identity.secret, "fixture-secret-access-key-0001")
        XCTAssertEqual(identity.sessionToken, "fixture-session-token-0001")
        XCTAssertNotNil(identity.expiration)
    }

    // MARK: - 2. Refresh: two resolutions obtain different synthetic credentials

    func test_secondResolution_afterFirstExpiration_obtainsDistinctSyntheticCredentials() async throws {
        let env = try makeFixtureEnvironment(mode: "success")
        let resolver = env.resolver()

        let first = try await resolver.getIdentity(identityProperties: nil)
        // The fixture's first invocation reports an already-past
        // Expiration, simulating a session that needs refreshing.
        let firstExpiration = try XCTUnwrap(first.expiration)
        XCTAssertLessThan(firstExpiration, Date())

        let second = try await resolver.getIdentity(identityProperties: nil)

        XCTAssertNotEqual(first.accessKey, second.accessKey)
        XCTAssertNotEqual(first.secret, second.secret)
        XCTAssertNotEqual(first.sessionToken, second.sessionToken)
        XCTAssertEqual(second.accessKey, "ASIAFIXTURETEST0002")
        let secondExpiration = try XCTUnwrap(second.expiration)
        XCTAssertGreaterThan(secondExpiration, Date())
    }

    // MARK: - 3. Nonzero exit maps to .credentialsUnavailable, no live Bedrock call

    func test_nonzeroExit_mapsToCredentialsUnavailable() async throws {
        let env = try makeFixtureEnvironment(mode: "nonzero")

        do {
            _ = try await env.resolver().getIdentity(identityProperties: nil)
            XCTFail("expected the fixture's nonzero exit to fail credential resolution")
        } catch {
            XCTAssertTrue(error is AWSCredentialIdentityResolverError)
            XCTAssertEqual(BedrockErrorMapper.map(error), .credentialsUnavailable)
        }
    }

    /// Same failure mode, but proven through the full production path:
    /// `BridgedBedrockClient.complete(...)` catches whatever the real SDK
    /// throws and maps it via `BedrockErrorMapper.map(_:)`. Credential
    /// resolution happens before request signing/dispatch, so a fixture
    /// failure here is caught before any live Bedrock network call would
    /// ever be attempted.
    func test_nonzeroExit_viaBridgedClient_mapsToCredentialsUnavailable_withoutLiveBedrockCall() async throws {
        let env = try makeFixtureEnvironment(mode: "nonzero")
        let client = try env.makeBridgedClient()

        let start = Date()
        do {
            _ = try await client.complete(system: "s", user: "u", maxTokens: 5)
            XCTFail("expected credential resolution to fail before any Bedrock call")
        } catch let bridged as BridgedBedrockError {
            XCTAssertEqual(bridged, .credentialsUnavailable)
        } catch {
            XCTFail("expected BridgedBedrockError, got \(type(of: error)): \(error)")
        }
        // A live Bedrock call over the network would take far longer than
        // this to fail; a fast failure is evidence none was attempted.
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    // MARK: - 4. Malformed JSON maps to .credentialsUnavailable via the same mapper path

    func test_malformedJSON_mapsToCredentialsUnavailable() async throws {
        let env = try makeFixtureEnvironment(mode: "malformed")

        do {
            _ = try await env.resolver().getIdentity(identityProperties: nil)
            XCTFail("expected the fixture's malformed JSON to fail credential resolution")
        } catch {
            XCTAssertTrue(error is AWSCredentialIdentityResolverError)
            XCTAssertEqual(BedrockErrorMapper.map(error), .credentialsUnavailable)
        }
    }

    func test_malformedJSON_viaBridgedClient_mapsToCredentialsUnavailable_withoutLiveBedrockCall() async throws {
        let env = try makeFixtureEnvironment(mode: "malformed")
        let client = try env.makeBridgedClient()

        do {
            _ = try await client.complete(system: "s", user: "u", maxTokens: 5)
            XCTFail("expected credential resolution to fail before any Bedrock call")
        } catch let bridged as BridgedBedrockError {
            XCTAssertEqual(bridged, .credentialsUnavailable)
        } catch {
            XCTFail("expected BridgedBedrockError, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - 5. Secret-shaped stderr never reaches a mapped BridgedBedrockError

    func test_secretShapedStderr_neverSurfacesInMappedError() async throws {
        let env = try makeFixtureEnvironment(mode: "leak-then-fail")

        var mapped: BridgedBedrockError?
        do {
            _ = try await env.resolver().getIdentity(identityProperties: nil)
            XCTFail("expected the fixture's leak-then-fail mode to fail credential resolution")
        } catch {
            XCTAssertTrue(error is AWSCredentialIdentityResolverError)
            mapped = BedrockErrorMapper.map(error)
        }

        let bridged = try XCTUnwrap(mapped)
        XCTAssertEqual(bridged, .credentialsUnavailable)

        // Structural guarantee, not just present behavior: `BridgedBedrockError`
        // cases are bare (no associated values -- see BedrockSDKBridge.swift),
        // so no string the fixture ever writes to stderr can be attached to
        // this value by construction. `Mirror` confirms there is nothing
        // attached to unwrap.
        XCTAssertTrue(Mirror(reflecting: bridged).children.isEmpty, "BridgedBedrockError must carry no associated value")

        // Belt-and-suspenders: every string this test can produce from the
        // mapped value is one of the fixed, safe case names -- never the
        // fixture's fake key, token, or command text.
        let renderedValue = String(describing: bridged)
        let renderedDump: String = {
            var out = ""
            dump(bridged, to: &out)
            return out
        }()
        for leaked in ["AKIAFAKEFIXTURELEAK0", "fake-fixture-session-token", "leak-then-fail", env.stateFilePath] {
            XCTAssertFalse(renderedValue.contains(leaked))
            XCTAssertFalse(renderedDump.contains(leaked))
        }
    }

    func test_secretShapedStderr_viaBridgedClient_neverSurfacesInThrownError() async throws {
        let env = try makeFixtureEnvironment(mode: "leak-then-fail")
        let client = try env.makeBridgedClient()

        do {
            _ = try await client.complete(system: "s", user: "u", maxTokens: 5)
            XCTFail("expected credential resolution to fail before any Bedrock call")
        } catch let bridged as BridgedBedrockError {
            XCTAssertEqual(bridged, .credentialsUnavailable)
            XCTAssertTrue(Mirror(reflecting: bridged).children.isEmpty)
        } catch {
            XCTFail("expected BridgedBedrockError, got \(type(of: error)): \(error)")
        }
    }
}
