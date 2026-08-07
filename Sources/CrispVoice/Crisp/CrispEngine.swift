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
    enum OutputError: LocalizedError, Equatable {
        case invalidStructuredResponse

        var errorDescription: String? {
            "Anthropic returned invalid message variants twice. Please try again."
        }
    }

    private let completer: TextCompleter
    private let variantCount: Int

    init(completer: TextCompleter, variantCount: Int = 3) {
        self.completer = completer
        self.variantCount = variantCount
    }

    func crisp(transcript: String, tone: Tone) async throws -> CrispResult {
        let user = CrispPrompt.user(transcript: transcript, tone: tone)
        let raw = try await completer.complete(
            system: CrispPrompt.system(variantCount: variantCount),
            user: user
        )

        do {
            return try CrispResult.parse(raw)
        } catch is CrispResult.ParseError {
            let retriedRaw = try await completer.complete(
                system: CrispPrompt.repairSystem(variantCount: variantCount),
                user: user
            )
            do {
                return try CrispResult.parse(retriedRaw)
            } catch is CrispResult.ParseError {
                throw OutputError.invalidStructuredResponse
            }
        }
    }
}
