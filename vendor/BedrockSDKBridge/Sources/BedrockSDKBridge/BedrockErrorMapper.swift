internal import AWSBedrockRuntime
internal import AWSSDKIdentity

/// Maps raw AWS SDK errors (from identity resolution and the Converse call)
/// to the closed `BridgedBedrockError` surface. Classification is always by
/// concrete error *type*, never by inspecting/embedding `localizedDescription`
/// or any other source text, so no credential, ARN, prompt, or response
/// content can leak into a returned value.
enum BedrockErrorMapper {
    static func map(_ error: Error) -> BridgedBedrockError {
        switch error {
        case is AWSCredentialIdentityResolverError:
            return .credentialsUnavailable
        case is AccessDeniedException:
            return .accessDenied
        case is ValidationException,
             is ResourceNotFoundException,
             is ModelNotReadyException:
            return .invalidModelOrRegion
        case is ThrottlingException,
             is ServiceQuotaExceededException:
            return .throttled
        default:
            // Includes transport/internal failures (e.g. InternalServerException,
            // ModelTimeoutException, ServiceUnavailableException, connectivity
            // errors) and any unrecognized error type.
            return .network
        }
    }
}
