import Foundation

/// The validated, immutable configuration needed to build a Bedrock
/// `TextCompleter`.
///
/// Construction normalizes a blank/whitespace profile to `default`, trims
/// leading/trailing whitespace from the Region and model ID, and throws
/// `.missingConfiguration` if the Region or model becomes empty after
/// trimming. It intentionally does not validate identifier punctuation,
/// infer a Region, or inspect any AWS files (design section 5.2).
struct BedrockConfiguration: Equatable {
    let profileName: String
    let region: String
    let modelID: String

    init(profileName: String, region: String, modelID: String) throws {
        let trimmedProfile = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRegion = region.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedRegion.isEmpty, !trimmedModelID.isEmpty else {
            throw RewriteProviderError.missingConfiguration
        }

        self.profileName = trimmedProfile.isEmpty ? "default" : trimmedProfile
        self.region = trimmedRegion
        self.modelID = trimmedModelID
    }
}
