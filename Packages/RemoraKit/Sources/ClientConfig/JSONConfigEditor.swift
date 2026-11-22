import Foundation

/// Reads and edits `mcpServers.<name>` in a client's JSON config, leaving every other key,
/// its order and its number spelling untouched. Anything it cannot round-trip is refused.
///
/// Edits re-serialize the whole document: the data is preserved exactly (keys, order, values,
/// number spelling), but formatting is normalized (indent detected, one value per line, `\n`
/// line ends, trailing newline). An edit that changes nothing returns the original bytes, so
/// callers can skip the write.
public enum JSONConfigEditor {
    public static func server(in data: Data?, name: String = "remora") throws(ConfigError) -> OrderedJSON? {
        guard let root = try parseRoot(data) else { return nil }
        guard let servers = try serversObject(of: root) else { return nil }
        return servers.first(where: { $0.0 == name })?.1
    }

    public static func upsertServer(in data: Data?, name: String = "remora", entry: OrderedJSON) throws(ConfigError) -> Data {
        let parsed = try parseRoot(data)
        var pairs = parsed?.objectPairs ?? []
        var servers = try serversObject(of: .object(pairs)) ?? []
        if let index = servers.firstIndex(where: { $0.0 == name }) {
            servers[index].1 = entry
        } else {
            servers.append((name, entry))
        }
        if let index = pairs.firstIndex(where: { $0.0 == "mcpServers" }) {
            pairs[index].1 = .object(servers)
        } else {
            pairs.append(("mcpServers", .object(servers)))
        }
        if let data, let parsed, parsed == .object(pairs) { return data }
        return OrderedJSON.object(pairs).serialized(indent: detectIndent(data))
    }

    public static func removeServer(in data: Data, name: String = "remora") throws(ConfigError) -> Data {
        guard var pairs = try parseRoot(data)?.objectPairs,
              var servers = try serversObject(of: .object(pairs)),
              let index = servers.firstIndex(where: { $0.0 == name }),
              let serversIndex = pairs.firstIndex(where: { $0.0 == "mcpServers" })
        else { return data }
        servers.remove(at: index)
        pairs[serversIndex].1 = .object(servers)
        return OrderedJSON.object(pairs).serialized(indent: detectIndent(data))
    }

    // MARK: -

    /// nil for absent or whitespace-only data. Verifies that re-serializing loses nothing.
    private static func parseRoot(_ data: Data?) throws(ConfigError) -> OrderedJSON? {
        guard let data, !isBlank(data) else { return nil }
        let original = try OrderedJSON.parse(data)
        guard case .object = original else { throw ConfigError.unexpectedShape("The settings file isn't a JSON object.") }
        guard try OrderedJSON.parse(original.serialized()) == original else { throw ConfigError.notRoundTrippable }
        return original
    }

    private static func serversObject(of root: OrderedJSON) throws(ConfigError) -> [(String, OrderedJSON)]? {
        guard let pairs = root.objectPairs, let entry = pairs.first(where: { $0.0 == "mcpServers" }) else { return nil }
        guard case .object(let servers) = entry.1 else { throw ConfigError.unexpectedShape("mcpServers isn't an object.") }
        return servers
    }

    private static func isBlank(_ data: Data) -> Bool {
        data.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
    }

    /// The number of spaces the file indents its first nested line with (2 when unknown).
    static func detectIndent(_ data: Data?) -> Int {
        guard let data else { return 2 }
        var spaces = 0
        var atLineStart = false
        var seenNewline = false
        for byte in data {
            if byte == 0x0A { atLineStart = true; seenNewline = true; spaces = 0; continue }
            guard seenNewline, atLineStart else { continue }
            if byte == 0x20 { spaces += 1; continue }
            if byte == 0x09 { return 2 }
            if spaces > 0 { return (1...8).contains(spaces) ? spaces : 2 }
            atLineStart = false
        }
        return 2
    }
}
