import Foundation

/// Minimal Anthropic Messages API client. Called directly from the user's
/// machine with the user's own key - no backend in the path.
final class AnthropicClient {
    enum ClientError: LocalizedError {
        /// `message` is the raw, untrusted response body captured at the
        /// point of failure. It exists on this case for completeness only —
        /// `errorDescription` and `diagnosticCode` below are derived solely
        /// from the non-secret HTTP status code, and no other code path may
        /// read `message` back out for logging or display (see
        /// `SafeErrorPresenter` and `SettingsModel.safeMessage`).
        case http(Int, String)
        case badResponse

        /// A stable diagnostic category safe to write to `DebugLog`.
        /// Derived only from the HTTP status code — never from the response
        /// body text.
        var diagnosticCode: String {
            switch self {
            case .http(let statusCode, _):
                switch statusCode {
                case 401, 403:
                    return "anthropic_authentication_error"
                case 429:
                    return "anthropic_throttled"
                case 500...599:
                    return "anthropic_server_error"
                default:
                    return "anthropic_request_error"
                }
            case .badResponse:
                return "anthropic_invalid_response"
            }
        }

        var errorDescription: String? {
            switch self {
            case .http(let statusCode, _):
                switch statusCode {
                case 401, 403:
                    return "Anthropic rejected the request due to an authentication or permission problem (HTTP \(statusCode)). Check your Anthropic API key in Settings."
                case 429:
                    return "Anthropic throttled this request (HTTP 429). Please try again in a moment."
                case 500...599:
                    return "Anthropic reported a server error (HTTP \(statusCode)). Please try again."
                default:
                    return "Anthropic request failed (HTTP \(statusCode))."
                }
            case .badResponse:
                return "Anthropic returned an unexpected response."
            }
        }
    }

    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    init(apiKey: String, model: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    private struct Response: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }

        let content: [Block]
    }

    private struct ErrorResponse: Decodable {
        struct APIError: Decodable {
            let type: String
            let message: String
        }

        let error: APIError
    }

    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [[
                "role": "user",
                "content": [[
                    "type": "text",
                    "text": user
                ]]
            ]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.badResponse
        }
        guard http.statusCode == 200 else {
            if let decoded = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw ClientError.http(http.statusCode, "\(decoded.error.type): \(decoded.error.message)")
            }
            throw ClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let text = decoded.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
        guard !text.isEmpty else {
            throw ClientError.badResponse
        }
        return text
    }
}

extension AnthropicClient: TextCompleter {
}
