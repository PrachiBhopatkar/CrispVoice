import XCTest
@testable import CrispVoice

final class RewriteProviderErrorTests: XCTestCase {
    private static let allCases: [RewriteProviderError] = [
        .missingConfiguration,
        .credentialsUnavailable,
        .accessDenied,
        .invalidModelOrRegion,
        .throttled,
        .network,
        .invalidResponse,
    ]

    private static let expectedDiagnosticCodes: [String] = [
        "missing_configuration",
        "credentials_unavailable",
        "access_denied",
        "invalid_model_or_region",
        "throttled",
        "network",
        "invalid_response",
    ]

    func test_allSevenCases_exposeStableDiagnosticCodes() {
        // Ordering matches `allCases` above one-to-one.
        for (error, expectedCode) in zip(Self.allCases, Self.expectedDiagnosticCodes) {
            XCTAssertEqual(error.diagnosticCode, expectedCode)
        }

        // Every code must be present and unique.
        let codes = Set(Self.allCases.map { $0.diagnosticCode })
        XCTAssertEqual(codes, Set(Self.expectedDiagnosticCodes))
        XCTAssertEqual(codes.count, 7)
    }

    func test_allSevenCases_haveActionableSafeLocalizedMessages() {
        for error in Self.allCases {
            guard let message = error.errorDescription, !message.isEmpty else {
                XCTFail("\(error) has no localized message")
                continue
            }
            // Every message must be a real sentence, not an empty/placeholder string.
            XCTAssertGreaterThan(message.count, 10, "\(error) message is not actionable: \(message)")
        }

        // Spot-check the required content from design section 9.
        XCTAssertTrue(RewriteProviderError.missingConfiguration.errorDescription!.contains("Region"))
        XCTAssertTrue(RewriteProviderError.missingConfiguration.errorDescription!.localizedCaseInsensitiveContains("model"))

        let credentialMessage = RewriteProviderError.credentialsUnavailable.errorDescription!
        XCTAssertTrue(credentialMessage.localizedCaseInsensitiveContains("refresh"))
        XCTAssertTrue(credentialMessage.localizedCaseInsensitiveContains("retry") || credentialMessage.localizedCaseInsensitiveContains("try again"))

        XCTAssertTrue(RewriteProviderError.accessDenied.errorDescription!.localizedCaseInsensitiveContains("administrator"))

        let invalidModelMessage = RewriteProviderError.invalidModelOrRegion.errorDescription!
        XCTAssertTrue(invalidModelMessage.contains("Region"))
        XCTAssertTrue(invalidModelMessage.localizedCaseInsensitiveContains("model"))

        XCTAssertTrue(RewriteProviderError.throttled.errorDescription!.localizedCaseInsensitiveContains("try again") || RewriteProviderError.throttled.errorDescription!.localizedCaseInsensitiveContains("retry"))
    }

    func test_noCaseCarriesAssociatedRawOrSourceErrorValue() {
        for error in Self.allCases {
            let mirror = Mirror(reflecting: error)
            XCTAssertEqual(mirror.children.count, 0, "\(error) unexpectedly carries associated data")
        }
    }

    func test_equatable_treatsSameCaseAsEqualAndDifferentCasesAsUnequal() {
        for error in Self.allCases {
            XCTAssertEqual(error, error)
        }

        for (index, lhs) in Self.allCases.enumerated() {
            for rhs in Self.allCases[(index + 1)...] {
                XCTAssertNotEqual(lhs, rhs)
            }
        }
    }
}
