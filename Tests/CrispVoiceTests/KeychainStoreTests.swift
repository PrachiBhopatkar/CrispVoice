import XCTest
@testable import CrispVoice

final class KeychainStoreTests: XCTestCase {
    private final class FakeKeychainBackend {
        var storage: [String: Data] = [:]

        func add(query: CFDictionary, _: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
            let dict = query as NSDictionary
            guard
                let service = dict[kSecAttrService as String] as? String,
                let account = dict[kSecAttrAccount as String] as? String,
                let data = dict[kSecValueData as String] as? Data
            else {
                return errSecParam
            }

            storage[key(service: service, account: account)] = data
            return errSecSuccess
        }

        func copyMatching(query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
            let dict = query as NSDictionary
            guard
                let service = dict[kSecAttrService as String] as? String,
                let account = dict[kSecAttrAccount as String] as? String
            else {
                return errSecParam
            }

            guard let data = storage[key(service: service, account: account)] else {
                return errSecItemNotFound
            }

            result?.pointee = data as CFTypeRef
            return errSecSuccess
        }

        func delete(query: CFDictionary) -> OSStatus {
            let dict = query as NSDictionary
            guard
                let service = dict[kSecAttrService as String] as? String,
                let account = dict[kSecAttrAccount as String] as? String
            else {
                return errSecParam
            }

            let key = key(service: service, account: account)
            if storage.removeValue(forKey: key) == nil {
                return errSecItemNotFound
            }
            return errSecSuccess
        }

        private func key(service: String, account: String) -> String {
            "\(service)::\(account)"
        }
    }

    private let service = "com.crispvoice.tests.\(UUID().uuidString)"

    private func makeStore() -> KeychainStore {
        let backend = FakeKeychainBackend()
        let client = KeychainStore.SecurityClient(
            add: backend.add(query:_:),
            copyMatching: backend.copyMatching(query:result:),
            delete: backend.delete(query:)
        )
        return KeychainStore(service: service, securityClient: client)
    }

    func test_saveThenRead_returnsValue() throws {
        let store = makeStore()
        try store.set("sk-secret")
        XCTAssertEqual(store.get(), "sk-secret")
    }

    func test_overwrite_updatesValue() throws {
        let store = makeStore()
        try store.set("first")
        try store.set("second")
        XCTAssertEqual(store.get(), "second")
    }

    func test_delete_removesValue() throws {
        let store = makeStore()
        try store.set("gone")
        try store.delete()
        XCTAssertNil(store.get())
    }
}
