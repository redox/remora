import Foundation

enum CallbackRejection: Error, Sendable, Equatable {
    /// Another method or path: answered 404, the attempt keeps waiting.
    case notFound
    /// Not a parseable request line (or an ambiguous query): answered 400, the attempt keeps waiting.
    case malformed
}

/// Parses the head of a request that reached the loopback listener. Only `GET /auth/callback?…`
/// is a callback; its query comes back percent-decoded. Values are secrets: never log them.
enum CallbackRequest {
    static func parse(requestHead: String) -> Result<[String: String], CallbackRejection> {
        let line = requestHead.prefix(while: { !$0.isNewline })
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3, !parts[0].isEmpty else { return .failure(.malformed) }
        if parts.count == 3, !parts[2].hasPrefix("HTTP/1.") { return .failure(.malformed) }
        // Origin-form only ("/path?query"); absolute-form and anything else is not ours.
        let target = parts[1]
        guard target.hasPrefix("/"), let components = URLComponents(string: "http://127.0.0.1\(target)") else {
            return .failure(.malformed)
        }
        // Compare the raw path, so an encoded "/auth%2Fcallback" does not match.
        guard parts[0] == "GET", components.percentEncodedPath == SIWC.callbackPath else { return .failure(.notFound) }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            // A repeated parameter (two `state`s, two `code`s) is ambiguous: reject it outright.
            guard query[item.name] == nil else { return .failure(.malformed) }
            query[item.name] = item.value ?? ""
        }
        return .success(query)
    }
}
