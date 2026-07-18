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

    func test_formalTone_instructsFormalLanguageAndGreeting() {
        let instruction = Tone.formal.instruction.lowercased()
        XCTAssertTrue(instruction.contains("formal"))
        XCTAssertTrue(instruction.contains("hello,"))
        XCTAssertTrue(instruction.contains("thank you,"))
        XCTAssertTrue(instruction.contains("exact structure"))
        XCTAssertTrue(instruction.contains("decisive"))
        XCTAssertTrue(instruction.contains("do not use filler"))
    }

    func test_user_embedsFormalToneInstruction() {
        let u = CrispPrompt.user(transcript: "can u send the report by friday", tone: .formal)
        XCTAssertTrue(u.contains("can u send the report by friday"))
        XCTAssertTrue(u.lowercased().contains("formal"))
    }

    func test_system_allowsGreetingExceptionForToneInstruction() {
        let s = CrispPrompt.system(variantCount: 3).lowercased()
        XCTAssertTrue(s.contains("unless the tone instruction below explicitly calls for one"))
    }
}
