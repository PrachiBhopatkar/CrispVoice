import Foundation

/// The result of presenting an error at the application boundary: a stable
/// diagnostic code safe to write to `DebugLog`, and a fixed, actionable
/// user-facing message. Never derived from raw SDK/error text.
struct SafeErrorPresentation: Equatable {
    let diagnosticCode: String
    let userMessage: String
}

/// The single seam through which every rewrite-provider failure (and any
/// other unexpected error) is translated into something safe to log and
/// show. `RewriteProviderError`'s own closed set of safe messages is
/// trusted as-is, and so are `AnthropicClient.ClientError` (status-code-only
/// category/description), `TranscriberError`, and `AppDelegateError` — all
/// four are closed, locally-authored enums with fixed, hardcoded messages
/// and no interpolated/dynamic content, so trusting their own
/// `errorDescription` cannot leak anything. Any other error type is treated
/// as unexpected and never inspected for its message/description, so no
/// credential, ARN, command, stderr, prompt, or response-body text it might
/// carry can reach a log or the UI.
struct SafeErrorPresenter {
    let writeDiagnostic: (String) -> Void

    func present(_ error: Error) -> SafeErrorPresentation {
        if let providerError = error as? RewriteProviderError {
            writeDiagnostic("AppDelegate.fail code=\(providerError.diagnosticCode)")
            return SafeErrorPresentation(
                diagnosticCode: providerError.diagnosticCode,
                userMessage: providerError.errorDescription ?? providerError.diagnosticCode
            )
        }

        if let clientError = error as? AnthropicClient.ClientError {
            writeDiagnostic("AppDelegate.fail code=\(clientError.diagnosticCode)")
            return SafeErrorPresentation(
                diagnosticCode: clientError.diagnosticCode,
                userMessage: clientError.errorDescription ?? clientError.diagnosticCode
            )
        }

        if let transcriberError = error as? TranscriberError {
            writeDiagnostic("AppDelegate.fail code=\(transcriberError.diagnosticCode)")
            return SafeErrorPresentation(
                diagnosticCode: transcriberError.diagnosticCode,
                userMessage: transcriberError.errorDescription ?? transcriberError.diagnosticCode
            )
        }

        if let appDelegateError = error as? AppDelegateError {
            writeDiagnostic("AppDelegate.fail code=\(appDelegateError.diagnosticCode)")
            return SafeErrorPresentation(
                diagnosticCode: appDelegateError.diagnosticCode,
                userMessage: appDelegateError.errorDescription ?? appDelegateError.diagnosticCode
            )
        }

        writeDiagnostic("AppDelegate.fail code=unexpected")
        return SafeErrorPresentation(
            diagnosticCode: "unexpected",
            userMessage: "Something went wrong. Please try again."
        )
    }
}
