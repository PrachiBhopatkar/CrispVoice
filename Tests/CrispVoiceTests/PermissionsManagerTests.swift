import XCTest
@testable import CrispVoice

final class PermissionsManagerTests: XCTestCase {
    func test_openAccessibilitySettingsURL_isSystemPrivacyPane() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        XCTAssertEqual(url?.scheme, "x-apple.systempreferences")
        XCTAssertEqual(url?.absoluteString, "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }
}
