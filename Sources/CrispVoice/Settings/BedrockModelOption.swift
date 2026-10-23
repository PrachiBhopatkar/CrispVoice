import Foundation

/// The Bedrock Settings model control: a friendly preset plus an opaque
/// custom identifier.
///
/// Normalization is intentionally limited to trimming leading/trailing
/// whitespace. CrispVoice never infers a Region from an identifier, never
/// validates identifier punctuation, and never rewrites internal
/// characters of a custom identifier (design section 6).
enum BedrockModelOption: Equatable {
    static let opus48USModelID = "us.anthropic.claude-opus-4-8"

    case opus48US
    case custom(String)

    /// The exact Bedrock Runtime `modelId` this option resolves to.
    var resolvedModelID: String {
        switch self {
        case .opus48US:
            return Self.opus48USModelID
        case .custom(let identifier):
            return identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Reconstructs the option that produced a stored/displayed model ID.
    static func from(modelID: String) -> BedrockModelOption {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == opus48USModelID {
            return .opus48US
        }
        return .custom(trimmed)
    }
}
