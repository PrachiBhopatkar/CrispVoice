import XCTest
@testable import CrispVoice

final class SuggestionModelTests: XCTestCase {
    func test_displayedTextsShowsTranscriptUntilVariantsArrive() {
        let model = SuggestionModel()

        model.transcript = "raw dictated transcript"
        XCTAssertEqual(model.displayedTexts, ["raw dictated transcript"])
        XCTAssertFalse(model.showsVariantButtons)

        model.variants = ["Crisp rewrite"]
        XCTAssertEqual(model.displayedTexts, ["Crisp rewrite"])
        XCTAssertTrue(model.showsVariantButtons)
    }

    // MARK: - Copy transcript

    func test_showsCopyTranscript_onlyWhenThereIsATranscript() {
        let model = SuggestionModel()
        XCTAssertFalse(model.showsCopyTranscript)

        model.transcript = "hello"
        XCTAssertTrue(model.showsCopyTranscript)
    }

    func test_showsCopyTranscript_staysAvailableAfterAFailure() {
        let model = SuggestionModel()
        model.transcript = "dictated text"
        model.hasFailed = true

        XCTAssertTrue(model.showsCopyTranscript)
    }

    // MARK: - Try again

    func test_showsRetry_whenFailedWithTranscriptAndNothingRunning() {
        let model = SuggestionModel()
        model.transcript = "dictated text"
        model.hasFailed = true

        XCTAssertTrue(model.showsRetry)
    }

    func test_showsRetry_isHiddenWithoutAFailure() {
        let model = SuggestionModel()
        model.transcript = "still listening"

        XCTAssertFalse(model.showsRetry)
    }

    func test_showsRetry_isHiddenWithoutATranscript() {
        let model = SuggestionModel()
        model.hasFailed = true

        XCTAssertFalse(model.showsRetry)
    }

    func test_showsRetry_isHiddenWhileWorkingOrOnceVariantsExist() {
        let model = SuggestionModel()
        model.transcript = "dictated text"
        model.hasFailed = true

        model.isWorking = true
        XCTAssertFalse(model.showsRetry)

        model.isWorking = false
        model.variants = ["Crisp rewrite"]
        XCTAssertFalse(model.showsRetry)
    }

    // MARK: - Reset

    func test_resetForNewCapture_clearsEverythingFromThePreviousAttempt() {
        let model = SuggestionModel()
        model.transcript = "old"
        model.variants = ["old rewrite"]
        model.hasFailed = true
        model.didCopy = true
        model.isWorking = true

        model.resetForNewCapture()

        XCTAssertEqual(model.transcript, "")
        XCTAssertTrue(model.variants.isEmpty)
        XCTAssertFalse(model.hasFailed)
        XCTAssertFalse(model.didCopy)
        XCTAssertFalse(model.isWorking)
        XCTAssertEqual(model.status, "Listening…")
    }

    // MARK: - Callbacks

    func test_closeCopyAndRetryCallbacksAreInvokedWithTheRightText() {
        let model = SuggestionModel()
        var closed = 0
        var copied: [String] = []
        var retried = 0
        model.onClose = { closed += 1 }
        model.onCopy = { copied.append($0) }
        model.onRetry = { retried += 1 }

        model.onClose()
        model.onCopy("some text")
        model.onRetry()

        XCTAssertEqual(closed, 1)
        XCTAssertEqual(copied, ["some text"])
        XCTAssertEqual(retried, 1)
    }
}
