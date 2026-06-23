import XCTest
@testable import CrispVoice

final class CrispPromptTests: XCTestCase {
    func test_system_requestsJSONVariantsAndCleanup() {
        let s = CrispPrompt.system(variantCount: 3)
        XCTAssertTrue(s.contains("JSON"))
        XCTAssertTrue(s.lowercased().contains("dictation"))
        XCTAssertTrue(s.lowercased().contains("do not invent"))
        XCTAssertTrue(s.lowercased().contains("repair obvious transcription errors"))
        XCTAssertTrue(s.lowercased().contains("non-words"))
        XCTAssertTrue(s.contains("3"))
    }

    func test_user_embedsRawTranscriptAndTone() {
        let u = CrispPrompt.user(transcript: "hey can u snd me teh deck", tone: .direct)
        XCTAssertTrue(u.contains("hey can u snd me teh deck"))
        XCTAssertTrue(u.lowercased().contains("direct"))
    }
}
