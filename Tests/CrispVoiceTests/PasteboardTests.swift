import XCTest
@testable import CrispVoice

final class PasteboardTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var subject: CrispVoice.Pasteboard!

    override func setUp() {
        super.setUp()
        let name = NSPasteboard.Name("PasteboardTests.\(UUID().uuidString)")
        pasteboard = NSPasteboard(name: name)
        pasteboard.clearContents()
        subject = CrispVoice.Pasteboard(pasteboard)
    }

    override func tearDown() {
        pasteboard.clearContents()
        subject = nil
        pasteboard = nil
        super.tearDown()
    }

    func test_setString_thenReadString_returnsSameValue() {
        subject.setString("hello crisp")
        XCTAssertEqual(subject.string(), "hello crisp")
    }

    func test_withTemporaryString_restoresPreviousContents() {
        subject.setString("original")
        subject.withTemporaryString("temp") {
            XCTAssertEqual(subject.string(), "temp")
        }
        XCTAssertEqual(subject.string(), "original")
    }
}
