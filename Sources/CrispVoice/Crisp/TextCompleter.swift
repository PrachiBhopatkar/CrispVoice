import Foundation

protocol TextCompleter {
    func complete(system: String, user: String, maxTokens: Int) async throws -> String
}
