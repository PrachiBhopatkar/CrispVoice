import XCTest
@testable import CrispVoice

final class AnthropicClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func requestBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var data = Data()
        while stream.hasBytesAvailable {
            let bytesRead = stream.read(buffer, maxLength: bufferSize)
            guard bytesRead >= 0 else {
                return nil
            }
            guard bytesRead > 0 else {
                break
            }
            data.append(buffer, count: bytesRead)
        }
        return data
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    func test_complete_sendsKeyAndReturnsAssistantText() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            XCTAssertEqual(request.value(forHTTPHeaderField: "content-type"), "application/json")

            let requestBody = self.requestBody(from: request)
            XCTAssertNotNil(requestBody)
            let jsonObject = try? JSONSerialization.jsonObject(with: requestBody ?? Data())
            let json = jsonObject as? [String: Any]
            XCTAssertNotNil(json)
            guard let json else {
                XCTFail("expected JSON request body")
                let resp = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                return (resp, Data())
            }
            XCTAssertEqual(json["model"] as? String, "claude-haiku-4-5-20251001")
            XCTAssertEqual(json["max_tokens"] as? Int, 64)
            XCTAssertEqual(json["system"] as? String, "sys")
            let messages = json["messages"] as? [[String: String]]
            XCTAssertNotNil(messages)
            XCTAssertEqual(messages, [["role": "user", "content": "usr"]])

            let responseBody = #"{"content":[{"type":"text","text":"{\"variants\":[\"Hi\"]}"}]}"#
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, responseBody.data(using: .utf8)!)
        }
        let client = AnthropicClient(apiKey: "sk-test", model: "claude-haiku-4-5-20251001", session: makeSession())
        let text = try await client.complete(system: "sys", user: "usr", maxTokens: 64)
        XCTAssertEqual(text, #"{"variants":["Hi"]}"#)
    }

    func test_complete_throwsOnNon200() async {
        MockURLProtocol.handler = { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (resp, Data("unauthorized".utf8))
        }
        let client = AnthropicClient(apiKey: "bad", model: "claude-haiku-4-5-20251001", session: makeSession())
        do {
            _ = try await client.complete(system: "s", user: "u", maxTokens: 64)
            XCTFail("expected throw")
        } catch let error as AnthropicClient.ClientError {
            guard case .http(let statusCode, let message) = error else {
                return XCTFail("expected http error, got \(error)")
            }
            XCTAssertEqual(statusCode, 401)
            XCTAssertEqual(message, "unauthorized")
        } catch {
            XCTFail("expected AnthropicClient.ClientError, got \(error)")
        }
    }
}
