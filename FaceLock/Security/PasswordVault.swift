import Foundation
import CryptoKit
import LocalAuthentication

enum PasswordVaultError: LocalizedError {
    case sessionNotArmed

    var errorDescription: String? {
        switch self {
        case .sessionNotArmed:
            return "Face unlock is not armed. Open Security settings and release the vault key with Touch ID once for this FaceLock session."
        }
    }
}

@MainActor
final class PasswordVault: ObservableObject {
    static let shared = PasswordVault()
    private let keyAccount = "mac-password-encryption-key-v2"
    private let ciphertextAccount = "mac-password-ciphertext-v2"
    private let manualBiometricGateKey = "passwordVaultUsesManualBiometricGate-v2"
    private let keychain = KeychainStore.shared
    private var sessionKeyData: Data?
    private var sessionCiphertext: Data?
    @Published private(set) var isArmed = false

    /// Menu construction and settings rendering must never summon authentication UI.
    /// A deliberate Store/Arm action is the only place FaceLock may ask for Touch ID.
    var hasPassword: Bool {
        (try? keychain.load(account: ciphertextAccount, allowAuthenticationUI: false)) != nil
    }

    func storeAfterBiometricAuthorization(password: String, context: LAContext) throws {
        guard context.evaluatedPolicyDomainState != nil else { throw LAError(.authenticationFailed) }
        let key = SymmetricKey(size: .bits256)
        var plaintext = Data(password.utf8)
        defer { plaintext.resetBytes(in: plaintext.indices) }
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let ciphertext = box.combined else { throw CocoaError(.coderInvalidValue) }
        try keychain.saveAfterFirstUnlock(ciphertext, account: ciphertextAccount)
        let keyData = key.withUnsafeBytes { Data($0) }
        do {
            try keychain.saveBiometricProtected(keyData, account: keyAccount)
            UserDefaults.standard.set(false, forKey: manualBiometricGateKey)
        } catch KeychainError.status(let status)
            where status == errSecMissingEntitlement || status == errSecParam {
            // Local/ad-hoc macOS builds may not have the provisioning metadata required
            // for access-control Keychain items. Touch ID is still required in `retrieve()`.
            try keychain.saveAfterFirstUnlock(keyData, account: keyAccount)
            UserDefaults.standard.set(true, forKey: manualBiometricGateKey)
        }
        cacheForSession(keyData)
        sessionCiphertext = ciphertext
    }

    func armSession() async throws {
        let prompt = "Release the FaceLock decryption key with Touch ID"
        let context = try await BiometricGate().authorizedContext(reason: prompt)
        guard let keyData = try loadKey(prompt: prompt, context: context) else {
            throw KeychainError.status(errSecItemNotFound)
        }
        guard let ciphertext = try keychain.load(account: ciphertextAccount) else {
            throw KeychainError.status(errSecItemNotFound)
        }
        cacheForSession(keyData)
        sessionCiphertext = ciphertext
    }

    func retrieve() async throws -> Data {
        guard let keyData = sessionKeyData else { throw PasswordVaultError.sessionNotArmed }
        let ciphertext: Data
        if let sessionCiphertext {
            ciphertext = sessionCiphertext
        } else if let storedCiphertext = try keychain.load(account: ciphertextAccount) {
            sessionCiphertext = storedCiphertext
            ciphertext = storedCiphertext
        } else {
            throw KeychainError.status(errSecItemNotFound)
        }
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: SymmetricKey(data: keyData))
    }

    private func loadKey(prompt: String, context: LAContext) throws -> Data? {
        if UserDefaults.standard.bool(forKey: manualBiometricGateKey) {
            return try keychain.load(account: keyAccount)
        } else {
            do {
                return try keychain.loadBiometricProtected(account: keyAccount,
                                                            prompt: prompt,
                                                            context: context)
            } catch KeychainError.status(let status)
                where status == errSecMissingEntitlement || status == errSecParam {
                return try keychain.load(account: keyAccount)
            }
        }
    }

    private func cacheForSession(_ keyData: Data) {
        clearSessionKey()
        sessionKeyData = keyData
        isArmed = true
    }

    private func clearSessionKey() {
        let byteCount = sessionKeyData?.count ?? 0
        sessionKeyData?.resetBytes(in: 0..<byteCount)
        sessionKeyData = nil
        let ciphertextByteCount = sessionCiphertext?.count ?? 0
        sessionCiphertext?.resetBytes(in: 0..<ciphertextByteCount)
        sessionCiphertext = nil
        isArmed = false
    }

    func delete() throws {
        clearSessionKey()
        try keychain.delete(account: ciphertextAccount)
        try keychain.delete(account: keyAccount)
        UserDefaults.standard.removeObject(forKey: manualBiometricGateKey)
    }
}
