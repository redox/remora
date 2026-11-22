import Dictation
import Foundation
import LLM
import Security

/// A separate, local Keychain item for the user-configured transcription key.
enum TranscriptionKeychain {
    private enum Failure: Error { case invalidKey, unavailable }

    private static var query: [String: Any] {
        KeychainCredentialStore.baseQuery(service: "dev.remora.dictation-transcription", account: "openai")
    }

    static func load() throws -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { throw Failure.unavailable }
        return key
    }

    static func save(_ input: String) throws {
        guard let key = OpenAITranscription.normalizedKey(input) else { throw Failure.invalidKey }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(key.utf8),
            kSecAttrLabel as String: "Remora: OpenAI dictation",
        ]
        let item = query
        switch SecItemUpdate(item as CFDictionary, attributes as CFDictionary) {
        case errSecSuccess: return
        case errSecItemNotFound:
            guard SecItemAdd(item.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess
            else { throw Failure.unavailable }
        default: throw Failure.unavailable
        }
    }

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.unavailable }
    }
}
