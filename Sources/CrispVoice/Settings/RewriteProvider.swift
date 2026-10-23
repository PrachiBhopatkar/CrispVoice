import Foundation

/// The user-selected destination for rewrite requests.
///
/// Exactly two cases exist. A missing, unknown, or corrupt persisted value
/// must resolve to `.anthropic` without deleting either provider's stored
/// settings (see `Preferences.rewriteProvider`).
enum RewriteProvider: String, CaseIterable, Identifiable {
    case anthropic
    case bedrock

    var id: String { rawValue }

    /// The user-facing title shown in the Settings provider picker.
    var title: String {
        switch self {
        case .anthropic:
            return "Anthropic API"
        case .bedrock:
            return "Amazon Bedrock"
        }
    }
}
