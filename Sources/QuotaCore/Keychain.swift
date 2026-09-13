import Foundation
import Security

/// Generic-password storage for the manually entered provider credentials
/// (session cookies, API keys, bearer tokens).
///
/// One item per provider under a shared service name, so revoking a single
/// provider never disturbs the others and `security find-generic-password`
/// can be used to inspect them.
public enum Keychain {
    public static let service = "bar.quota.QuotaBar"

    public static func read(account: String, service: String = Keychain.service) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    /// Upserts the item. Returns false when the keychain refuses the write, so
    /// callers can surface a real error instead of silently dropping the secret.
    @discardableResult
    public static func write(_ value: String, account: String, service: String = Keychain.service) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }

        var insert = base
        insert[kSecValueData as String] = data
        // Available without an unlocked login keychain prompt after the first
        // unlock, and never synced to iCloud — these are machine-local sessions.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        insert[kSecAttrSynchronizable as String] = false
        insert[kSecAttrLabel as String] = "QuotaBar — \(account)"
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public static func delete(account: String, service: String = Keychain.service) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// Indirection so tests can exercise `ConfigStore` without touching the real
/// login keychain (which would prompt, and would leak between test runs).
public protocol CredentialStorage: Sendable {
    func read(account: String) -> String?
    @discardableResult func write(_ value: String, account: String) -> Bool
    @discardableResult func delete(account: String) -> Bool
}

public struct KeychainStorage: CredentialStorage {
    public init() {}
    public func read(account: String) -> String? { Keychain.read(account: account) }
    @discardableResult public func write(_ value: String, account: String) -> Bool {
        Keychain.write(value, account: account)
    }
    @discardableResult public func delete(account: String) -> Bool {
        Keychain.delete(account: account)
    }
}

/// In-memory stand-in used by the test suite.
public final class MemoryCredentialStorage: CredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]

    public init(_ seed: [String: String] = [:]) {
        items = seed
    }

    public func read(account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return items[account]
    }

    @discardableResult public func write(_ value: String, account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        items[account] = value
        return true
    }

    @discardableResult public func delete(account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        items[account] = nil
        return true
    }
}
