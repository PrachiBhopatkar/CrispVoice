import Foundation

protocol TextCompleter {
    func complete(system: String, user: String) async throws -> String
}

extension AnthropicClient: TextCompleter {
    func complete(system: String, user: String) async throws -> String {
        try await complete(system: system, user: user, maxTokens: 1024)
    }
}

final class CrispEngine {
    private let completer: TextCompleter
    private let variantCount: Int

    init(completer: TextCompleter, variantCount: Int = 3) {
        self.completer = completer
        self.variantCount = variantCount
    }

    func crisp(transcript: String, tone: Tone) async throws -> CrispResult {
        let system = CrispPrompt.system(variantCount: variantCount)
        let user = CrispPrompt.user(transcript: transcript, tone: tone)
        let raw = try await completer.complete(system: system, user: user)
        return try CrispResult.parse(raw)
    }
}
