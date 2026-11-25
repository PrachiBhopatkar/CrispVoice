import XCTest
@testable import CrispVoice

final class ToolPathTests: XCTestCase {
    private let home = "/Users/test"

    func test_appendsExistingStandardDirectoriesAfterCurrentPath() {
        let existing: Set<String> = [
            "/Users/test/.toolbox/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin"
        ]

        let result = ToolPath.augmented(
            current: "/usr/bin:/bin",
            home: home,
            directoryExists: { existing.contains($0) }
        )

        XCTAssertEqual(
            result,
            "/usr/bin:/bin:/Users/test/.toolbox/bin:/opt/homebrew/bin:/usr/local/bin"
        )
    }

    func test_skipsDirectoriesThatDoNotExist() {
        let result = ToolPath.augmented(
            current: "/usr/bin:/bin",
            home: home,
            directoryExists: { _ in false }
        )

        XCTAssertEqual(result, "/usr/bin:/bin")
    }

    func test_doesNotDuplicateOrReorderEntriesAlreadyPresent() {
        let result = ToolPath.augmented(
            current: "/usr/local/bin:/usr/bin:/bin",
            home: home,
            directoryExists: { _ in true }
        )

        XCTAssertTrue(result.hasPrefix("/usr/local/bin:/usr/bin:/bin"))
        XCTAssertEqual(
            result.split(separator: ":").filter { $0 == "/usr/local/bin" }.count,
            1
        )
    }

    func test_handlesMissingOrEmptyCurrentPath() {
        let existing: Set<String> = ["/opt/homebrew/bin"]

        XCTAssertEqual(
            ToolPath.augmented(current: nil, home: home, directoryExists: { existing.contains($0) }),
            "/opt/homebrew/bin"
        )
        XCTAssertEqual(
            ToolPath.augmented(current: "", home: home, directoryExists: { existing.contains($0) }),
            "/opt/homebrew/bin"
        )
    }
}
