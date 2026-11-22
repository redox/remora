import Foundation
import Synchronization

public protocol CredentialStore: Sendable {
    func load() throws -> SIWCAccount?
    func save(_ a: SIWCAccount) throws
    func delete() throws
}

/// Process-memory store for tests and previews.
public final class InMemoryCredentialStore: CredentialStore {
    private let account: Mutex<SIWCAccount?>

    public init(_ initial: SIWCAccount? = nil) {
        account = Mutex(initial)
    }

    public func load() throws -> SIWCAccount? { account.withLock { $0 } }
    public func save(_ a: SIWCAccount) throws { account.withLock { $0 = a } }
    public func delete() throws { account.withLock { $0 = nil } }
}
