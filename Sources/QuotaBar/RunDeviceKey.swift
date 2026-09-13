import CryptoKit
import Foundation
import QuotaCore

/// This Mac's Quota Run signing key: the device's login, since there are no
/// passwords.
///
/// In the Secure Enclave when the Mac has one — the private key then cannot
/// leave the chip, and what the keychain holds is an opaque handle only this
/// Mac's enclave can use. Otherwise a software P-256 key, whose bytes the
/// login keychain holds. Either way the keychain item is the one place the
/// key persists, it is never written to a file, and nothing here logs it.
enum RunDeviceKey {
    static let service = "bar.quota.run.device-key"
    private static let account = "device"

    enum Kind: String {
        case secureEnclave = "se"
        case software = "sw"
    }

    private struct EnclaveSigner: RunSigner, @unchecked Sendable {
        let key: SecureEnclave.P256.Signing.PrivateKey

        var publicKeyX963: Data { key.publicKey.x963Representation }

        func signature(for data: Data) throws -> Data {
            try key.signature(for: data).derRepresentation
        }
    }

    enum KeyError: Error {
        case keychainRefused
    }

    /// The stored key, or nil when this Mac has none (or the keychain will
    /// not hand it over).
    static func load() -> (signer: RunSigner, kind: Kind)? {
        guard let stored = Keychain.read(account: account, service: service) else { return nil }
        let parts = stored.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let kind = Kind(rawValue: parts[0]), let data = Data(base64Encoded: parts[1]) else { return nil }
        switch kind {
        case .secureEnclave:
            guard SecureEnclave.isAvailable,
                  let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data)
            else { return nil }
            return (EnclaveSigner(key: key), kind)
        case .software:
            guard let key = try? P256.Signing.PrivateKey(rawRepresentation: data) else { return nil }
            return (SoftwareRunSigner(key: key), kind)
        }
    }

    /// A fresh key, replacing any stored one. Joining calls this; a key is
    /// never reused across memberships.
    static func create() throws -> (signer: RunSigner, kind: Kind) {
        let made: (RunSigner, Kind, Data)
        if SecureEnclave.isAvailable, let key = try? SecureEnclave.P256.Signing.PrivateKey() {
            made = (EnclaveSigner(key: key), .secureEnclave, key.dataRepresentation)
        } else {
            // No enclave, or it refused (an unsigned build can be refused):
            // the software key is still a real key, just a copyable one.
            let key = P256.Signing.PrivateKey()
            made = (SoftwareRunSigner(key: key), .software, key.rawRepresentation)
        }
        let value = "\(made.1.rawValue):\(made.2.base64EncodedString())"
        guard Keychain.write(value, account: account, service: service) else { throw KeyError.keychainRefused }
        return (made.0, made.1)
    }

    static func delete() {
        Keychain.delete(account: account, service: service)
    }
}
