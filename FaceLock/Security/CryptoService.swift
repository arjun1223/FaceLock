import Foundation
import CryptoKit

struct CryptoService {
    private let keyAccount = "face-profile-aes-key"
    private let keychain = KeychainStore.shared

    private func key() throws -> SymmetricKey {
        if let data = try keychain.load(account: keyAccount) { return SymmetricKey(data: data) }
        let key = SymmetricKey(size: .bits256)
        try keychain.save(key.withUnsafeBytes { Data($0) }, account: keyAccount)
        return key
    }

    func encrypt(_ data: Data) throws -> Data {
        let sealed = try AES.GCM.seal(data, using: key())
        guard let combined = sealed.combined else { throw CocoaError(.coderInvalidValue) }
        return combined
    }

    func decrypt(_ data: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key())
    }

    func deleteKey() throws { try keychain.delete(account: keyAccount) }
}
