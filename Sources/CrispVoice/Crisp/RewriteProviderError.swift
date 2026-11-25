import Foundation
import BedrockSDKBridge

/// A closed, app-owned safe error enum shared by every rewrite provider.
///
/// AWS SDK, Bedrock, SSO, and credential-provider failures are translated
/// into one of these seven cases before they ever reach `AppDelegate` or
/// Settings (see design section 9). None of these cases carries an
/// associated raw/source error value: only the stable diagnostic code and
/// a fixed, safe, actionable message are ever exposed.
enum RewriteProviderError: LocalizedError, Equatable {
    case missingConfiguration
    case credentialsUnavailable
    case accessDenied
    case invalidModelOrRegion
    case throttled
    case network
    case invalidResponse

    /// A stable identifier safe to write to `DebugLog`. Never derived from
    /// or containing any raw SDK/error text.
    var diagnosticCode: String {
        switch self {
        case .missingConfiguration:
            return "missing_configuration"
        case .credentialsUnavailable:
            return "credentials_unavailable"
        case .accessDenied:
            return "access_denied"
        case .invalidModelOrRegion:
            return "invalid_model_or_region"
        case .throttled:
            return "throttled"
        case .network:
            return "network"
        case .invalidResponse:
            return "invalid_response"
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "Choose an AWS Region and model in Settings before using this rewrite provider."
        case .credentialsUnavailable:
            return "CrispVoice couldn't get AWS credentials. Your login may have expired, or your profile's credential helper may not be launchable from the app. Refresh your normal AWS or company login, then try again. See docs/troubleshooting.md."
        case .accessDenied:
            return "The selected AWS role doesn't have permission to use this model or inference profile. Contact your AWS administrator."
        case .invalidModelOrRegion:
            return "Check the AWS Region and model or inference-profile identifier in Settings."
        case .throttled:
            return "The rewrite provider throttled this request. Please try again in a moment."
        case .network:
            return "A network connection failure prevented the request from completing. Please try again."
        case .invalidResponse:
            return "The rewrite provider returned an invalid or empty response. Please try again."
        }
    }
}

extension RewriteProviderError {
    /// Translates the Bedrock vendor package's closed error surface into
    /// this app-owned error. `BridgedBedrockError` itself carries no raw
    /// SDK/error text (see `vendor/BedrockSDKBridge`), so this mapping
    /// cannot leak anything beyond the stable classification.
    init(bridged: BridgedBedrockError) {
        switch bridged {
        case .credentialsUnavailable: self = .credentialsUnavailable
        case .accessDenied: self = .accessDenied
        case .invalidModelOrRegion: self = .invalidModelOrRegion
        case .throttled: self = .throttled
        case .network: self = .network
        case .invalidResponse: self = .invalidResponse
        }
    }
}
