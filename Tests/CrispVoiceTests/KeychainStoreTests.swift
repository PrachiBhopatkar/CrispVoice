import XCTest
@testable import CrispVoice

final class KeychainStoreTests: XCTestCase {
    private let service = "com.crispvoice.tests.\(UUID().uuidString)"

    func test_saveThenRead_returnsValue() throws {
        let store = KeychainStore(service: service)
        try store.set("sk-secret")
        XCTAssertEqual(store.get(), "sk-secret")
    }

    func test_overwrite_updatesValue() throws {
        let store = KeychainStore(service: service)
        try store.set("first")
        try store.set("second")
        XCTAssertEqual(store.get(), "second")
    }

    func test_delete_removesValue() throws {
        let store = KeychainStore(service: service)
        try store.set("gone")
        try store.delete()
        XCTAssertNil(store.get())
    }
}
