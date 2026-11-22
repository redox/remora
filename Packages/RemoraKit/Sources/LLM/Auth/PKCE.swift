import CryptoKit
import Foundation

public struct PKCE: Sendable, Equatable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String, challenge: String) {
        self.verifier = verifier
        self.challenge = challenge
    }

    /// 48 random bytes, base64url without padding (64 characters), S256 challenge.
    public static func make() -> PKCE {
        let verifier = RandomToken.make(bytes: 48)
        return PKCE(verifier: verifier, challenge: challenge(for: verifier))
    }

    public static func challenge(for verifier: String) -> String {
        Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}

extension PKCE: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private var redactedFields: KeyValuePairs<String, Any> {
        ["verifier": Redacted.secret(verifier), "challenge": Redacted.secret(challenge)]
    }
    public var description: String { Redacted.describe("PKCE", redactedFields) }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: redactedFields, displayStyle: .struct) }
}

/// Random base64url strings for `state` and `nonce`.
public enum RandomToken {
    public static func make(bytes: Int = 24) -> String {
        var generator = SystemRandomNumberGenerator()
        return Base64URL.encode(Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }
}
