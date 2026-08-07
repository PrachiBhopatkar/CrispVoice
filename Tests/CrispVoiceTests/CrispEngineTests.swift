import XCTest
@testable import CrispVoice

private final class PromptCapture {
    var systems: [String] = []
    var users: [String] = []
}

private enum StubError: Error, Equatable {
    case transport
}

private final class SequencedCompleter: TextCompleter {
    private var results: [Result<String, Error>]
    let capture: PromptCapture

    init(results: [Result<String, Error>], capture: PromptCapture = PromptCapture()) {
        self.results = results
        self.capture = capture
    }

    func complete(system: String, user: String) async throws -> String {
        capture.systems.append(system)
        capture.users.append(user)
        guard !results.isEmpty else {
            XCTFail("unexpected completion request")
            throw StubError.transport
        }
        return try results.removeFirst().get()
    }
}

final class CrispEngineTests: XCTestCase {
    func test_crisp_returnsParsedVariants() async throws {
        let capture = PromptCapture()
        let completer = SequencedCompleter(
            results: [
                .success(#"{"variants":["Send the deck please.","Please share the deck."]}"#)
            ],
            capture: capture
        )
        let engine = CrispEngine(completer: completer, variantCount: 2)

        let result = try await engine.crisp(transcript: "snd me teh deck", tone: .neutral)

        XCTAssertEqual(result.variants.count, 2)
        XCTAssertEqual(result.variants.first, "Send the deck please.")
        XCTAssertEqual(capture.systems.count, 1)
        XCTAssertTrue(capture.systems[0].contains(#""variants": ["...", "..."]"#))
        XCTAssertTrue(capture.systems[0].contains("exactly 2"))
        XCTAssertTrue(capture.users[0].contains("snd me teh deck"))
        XCTAssertTrue(capture.users[0].contains(Tone.neutral.instruction))
    }

    func test_crisp_retriesOnceAfterParseFailureAndReturnsSecondResult() async throws {
        let capture = PromptCapture()
        let completer = SequencedCompleter(results: [
            .success("not valid variants JSON"),
            .success(#"{"variants":["Hello,\n\nPlease use \"pods\".\n\nThank you,"]}"#)
        ], capture: capture)
        let engine = CrispEngine(completer: completer, variantCount: 1)

        let result = try await engine.crisp(transcript: "I said pods", tone: .formal)

        XCTAssertEqual(result.variants, ["Hello,\n\nPlease use \"pods\".\n\nThank you,"])
        XCTAssertEqual(capture.systems.count, 2)
        XCTAssertEqual(capture.users.count, 2)
        XCTAssertEqual(capture.users[0], capture.users[1])
        XCTAssertEqual(capture.systems[1], CrispPrompt.repairSystem(variantCount: 1))
    }

    func test_crisp_stopsAfterSecondParseFailureWithLocalizedError() async {
        let capture = PromptCapture()
        let completer = SequencedCompleter(results: [
            .success("not JSON"),
            .success(#"{"variants":[{"text":"wrong shape"}]}"#)
        ], capture: capture)
        let engine = CrispEngine(completer: completer, variantCount: 1)

        do {
            _ = try await engine.crisp(transcript: "test", tone: .formal)
            XCTFail("expected invalidStructuredResponse")
        } catch let error as CrispEngine.OutputError {
            XCTAssertEqual(error, .invalidStructuredResponse)
            XCTAssertEqual(
                error.localizedDescription,
                "Anthropic returned invalid message variants twice. Please try again."
            )
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(capture.systems.count, 2)
    }

    func test_crisp_doesNotRetryNonParseFailure() async {
        let capture = PromptCapture()
        let completer = SequencedCompleter(
            results: [.failure(StubError.transport)],
            capture: capture
        )
        let engine = CrispEngine(completer: completer, variantCount: 1)

        do {
            _ = try await engine.crisp(transcript: "test", tone: .formal)
            XCTFail("expected transport error")
        } catch let error as StubError {
            XCTAssertEqual(error, .transport)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(capture.systems.count, 1)
    }

    func test_crisp_propagatesNonParseFailureFromRetryWithoutThirdRequest() async {
        let capture = PromptCapture()
        let completer = SequencedCompleter(
            results: [
                .success("not JSON"),
                .failure(StubError.transport)
            ],
            capture: capture
        )
        let engine = CrispEngine(completer: completer, variantCount: 1)

        do {
            _ = try await engine.crisp(transcript: "test", tone: .formal)
            XCTFail("expected transport error")
        } catch let error as StubError {
            XCTAssertEqual(error, .transport)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(capture.systems.count, 2)
    }
}
