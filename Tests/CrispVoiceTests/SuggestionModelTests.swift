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
}
