import Foundation

/// Adds related search terms (French/English equivalents, synonyms) before memory retrieval.
public protocol QueryExpander: Sendable {
    /// `terms` first, then the added terms. Never fails: on any error, or once `timeout` has
    /// passed, it returns `terms` unchanged. `cloudAllowed` is the rewrite's own permission (the
    /// rewrite gate's `RewriteAccess.cloudAllowed`): false means the on-device model or nothing.
    func expand(_ terms: [String], cloudAllowed: Bool, timeout: Duration) async -> [String]
}

/// No expansion: the terms as given.
public struct NoExpansion: QueryExpander {
    public init() {}
    public func expand(_ terms: [String], cloudAllowed: Bool, timeout: Duration) async -> [String] { terms }
}
