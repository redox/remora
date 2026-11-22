import Foundation
import Security

public struct KeychainError: Error, Sendable, Equatable {
    public let status: OSStatus
}

/// One generic-password item holding the account as JSON, in the legacy file keychain
/// (no data-protection keychain: that would need a provisioning profile). In the file keychain the
/// item is protected by its access-control list (the creating app is trusted) and by the login
/// keychain's lock; `kSecAttrAccessible` is recorded but largely not enforced there. The item is
/// never synchronizable. Unit tests exercise only the static query/encoding helpers, never `SecItem*`.
public struct KeychainCredentialStore: CredentialStore {
    public let service: String
    public let account: String

    static let label = "Remora: ChatGPT sign-in"

    public init(service: String = "dev.remora.Remora.siwc", account: String = "chatgpt") {
        self.service = service
        self.account = account
    }

    public static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    /// Attributes written on add and update.
    static func writeAttributes(data: Data) -> [String: Any] {
        [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrLabel as String: label,
        ]
    }

    static func encode(_ a: SIWCAccount) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(a)
    }

    static func decode(_ data: Data) throws -> SIWCAccount {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(SIWCAccount.self, from: data)
    }

    public func load() throws -> SIWCAccount? {
        var query = Self.baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return try Self.decode(data)
    }

    public func save(_ a: SIWCAccount) throws {
        let data = try Self.encode(a)
        let query = Self.baseQuery(service: service, account: account)
        let attributes = Self.writeAttributes(data: data)
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }
        let addStatus = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    }

    public func delete() throws {
        let status = SecItemDelete(Self.baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
