import XCTest
@testable import CrispVoice

final class PreferencesTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "com.crispvoice.tests.preferences.\(UUID().uuidString)")!
    }

    func test_defaults_areSensible() {
        let prefs = Preferences(defaults: freshDefaults())

        XCTAssertEqual(prefs.modelName, "claude-haiku-4-5-20251001")
        XCTAssertEqual(prefs.variantCount, 3)
    }

    func test_setters_persist() {
        let defaults = freshDefaults()
        let prefs = Preferences(defaults: defaults)

        prefs.modelName = "claude-sonnet-4-5-20250929"
        prefs.variantCount = 2

        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.modelName, "claude-sonnet-4-5-20250929")
        XCTAssertEqual(reloaded.variantCount, 2)
    }
}
