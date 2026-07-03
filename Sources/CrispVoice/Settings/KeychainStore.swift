import Foundation
import Security

/// Stores the Anthropic API key in the macOS Keychain. The key never leaves
/// the machine except in the user's own Anthropic request.
final class KeychainStore {
    struct SecurityClient {
        var add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
        var copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
        var delete: (CFDictionary) -> OSStatus

        static let live = SecurityClient(
            add: SecItemAdd,
            copyMatching: SecItemCopyMatching,
            delete: SecItemDelete
        )
    }

    enum KeychainError: Error {
        case unexpected(OSStatus)
    }

    private let service: String
    private let account = "anthropic-api-key"
    private let securityClient: SecurityClient

    init(
        service: String = "com.crispvoice.app",
        securityClient: SecurityClient = .live
    ) {
        self.service = service
        self.securityClient = securityClient
    }

    func set(_ value: String) throws {
        DebugLog.write("KeychainStore.set called service=\(service) length=\(value.count)")
        try? delete()

        // Create an access object with no trusted-app restriction so any build of this
        // app can read the key without triggering a Keychain password dialog on rebuild.
        var secAccess: SecAccess?
        SecAccessCreate("CrispVoice API Key" as CFString, nil, &secAccess)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8)
        ]
        if let secAccess {
            query[kSecAttrAccess as String] = secAccess
        }

        let status = securityClient.add(query as CFDictionary, nil)
        DebugLog.write("KeychainStore.set add status=\(status)")
        guard status == errSecSuccess else {
            throw KeychainError.unexpected(status)
        }
    }

    func get() -> String? {
        DebugLog.write("KeychainStore.get called service=\(service)")
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // Never show a Keychain password dialog — fail immediately if interaction is required.
            // This prevents the 20-second hang when the stored item was created by a different binary.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]

        var item: CFTypeRef?
        let status = securityClient.copyMatching(query as CFDictionary, &item)
        DebugLog.write("KeychainStore.get status=\(status)")

        if status == errSecInteractionNotAllowed {
            // Item exists but was created by a previous binary — silently remove it so the
            // user can re-enter their key and save it with the new open-access policy.
            DebugLog.write("KeychainStore.get interactionRequired removing stale entry")
            try? delete()
            return nil
        }

        guard status == errSecSuccess,
              let data = item as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    func delete() throws {
        DebugLog.write("KeychainStore.delete called service=\(service)")
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = securityClient.delete(query as CFDictionary)
        DebugLog.write("KeychainStore.delete status=\(status)")
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpected(status)
        }
    }
}
