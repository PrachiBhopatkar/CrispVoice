import XCTest
@testable import CrispVoice

final class CrispResultTests: XCTestCase {
    func test_parse_acceptsEscapedFormalLineBreaksAndQuotedTerms() throws {
        let json = #"{"variants":["Hello,\n\nPlease use \"pods\" or \"pod pods\".\n\nThank you,"]}"#

        let result = try CrispResult.parse(json)

        XCTAssertEqual(
            result.variants,
            ["Hello,\n\nPlease use \"pods\" or \"pod pods\".\n\nThank you,"]
        )
    }

    func test_parse_extractsVariantsFromCleanJSON() throws {
        let json = #"{"variants": ["Can you send me the deck?", "Please share the deck."]}"#
        let result = try CrispResult.parse(json)
        XCTAssertEqual(result.variants, ["Can you send me the deck?", "Please share the deck."])
    }

    func test_parse_toleratesSurroundingProseAndCodeFences() throws {
        let messy = "Sure!\n```json\n{\"variants\": [\"Hello there.\"]}\n```\nHope that helps."
        let result = try CrispResult.parse(messy)
        XCTAssertEqual(result.variants, ["Hello there."])
    }

    func test_parse_ignoresLaterBracesInSurroundingProse() throws {
        let messy = "{\"variants\": [\"Hello there.\"]}\nNote: use {formal} tone."
        let result = try CrispResult.parse(messy)
        XCTAssertEqual(result.variants, ["Hello there."])
    }

    func test_parse_throwsOnNoJSON() {
        XCTAssertThrowsError(try CrispResult.parse("no json here"))
    }
}
