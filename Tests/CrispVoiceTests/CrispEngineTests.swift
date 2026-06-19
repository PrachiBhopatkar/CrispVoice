import XCTest
@testable import CrispVoice

private final class PromptCapture {
    var system = ""
    var user = ""
}

private struct StubCompleter: TextCompleter {
    let canned: String
    let capture: PromptCapture

    func complete(system: String, user: String) async throws -> String {
        capture.system = system
        capture.user = user
        return canned
    }
}

final class CrispEngineTests: XCTestCase {
    func test_crisp_returnsParsedVariants() async throws {
        let capture = PromptCapture()
        let stub = StubCompleter(
            canned: #"{"variants":["Send the deck please.","Please share the deck."]}"#,
            capture: capture
        )
        let engine = CrispEngine(completer: stub, variantCount: 2)

        let result = try await engine.crisp(transcript: "snd me teh deck", tone: .neutral)

        XCTAssertEqual(result.variants.count, 2)
        XCTAssertEqual(result.variants.first, "Send the deck please.")
        XCTAssertTrue(capture.system.contains(#""variants": ["...", "..."]"#))
        XCTAssertTrue(capture.system.contains("exactly 2"))
        XCTAssertTrue(capture.user.contains("snd me teh deck"))
        XCTAssertTrue(capture.user.contains(Tone.neutral.instruction))
    }
}
