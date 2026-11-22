import Foundation
import Storage

public enum MeetingImportError: Error, Equatable {
    case invalidEndpoint, incompatibleServer, invalidResponse, responseTooLarge, toolFailed
    case toolUnavailable, signInRequired, signInFailed, paused, excluded, alreadySyncing
    case httpStatus(Int)
}

public struct MeetingEndpoint: Sendable {
    public static let granola = "https://mcp.granola.ai/mcp"
    public let url: URL

    public init(_ provider: MeetingSource.Provider, _ input: String) throws {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: input), let url = parts.url,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw MeetingImportError.invalidEndpoint
        }
        if provider == .granola {
            guard input == Self.granola else { throw MeetingImportError.invalidEndpoint }
        } else {
            guard parts.scheme == "http",
                  let host = parts.host?.lowercased(),
                  ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host),
                  let port = parts.port, (1...65535).contains(port) else {
                throw MeetingImportError.invalidEndpoint
            }
        }
        self.url = url
    }
}
