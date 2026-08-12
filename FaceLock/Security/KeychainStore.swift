import Foundation
import Security
import LocalAuthentication

enum KeychainError: LocalizedError {
    case status(OSStatus)
    var errorDescription: String? {
        guard case let .status(status) = self else { return nil }
        return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    }
}

struct KeychainStore {
    static let shared = KeychainStore()
    /// Versioned for the 1.0.3 public package. These downloads are ad-hoc signed,
    /// so a new binary cannot safely assume macOS will authorize access to an
    /// earlier build's items without showing the login-Keychain password dialog.
    static let service = "io.github.arjun1223.FaceLock.credentials.v4"

    private func baseQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account]
    }

    func save(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    func saveAfterFirstUnlock(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    func saveBiometricProtected(_ data: Data, account: String) throws {
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil,
                                                          kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                                          .biometryCurrentSet,
                                                          &accessError) else {
            if let error = accessError?.takeRetainedValue() {
                throw KeychainError.status(OSStatus(CFErrorGetCode(error)))
            }
            throw CocoaError(.coderInvalidValue)
        }
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessControl as String] = access
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    func loadBiometricProtected(account: String, prompt: String, context: LAContext) throws -> Data? {
        context.localizedReason = prompt
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        return result as? Data
    }

    func load(account: String, allowAuthenticationUI: Bool = true) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowAuthenticationUI {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        return result as? Data
    }

    func delete(account: String) throws {
        let query = baseQuery(account: account)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}
