import Foundation

/// A deliberately small line scanner for Codex's `config.toml`. It is not a TOML parser: it
/// finds the `[mcp_servers.remora]` table, reads its `command`, appends or removes that one
/// table, and refuses any layout it can't reason about.
public enum CodexTOML {
    public static func serverCommand(in text: String) throws(ConfigError) -> String? {
        let scan = try Scan(text)
        guard let table = scan.table else { return nil }
        var found: String?
        for index in (table.header + 1)..<table.end where scan.lines[index].structural {
            guard let (key, value) = splitKeyValue(scan.lines[index].text), key == ["command"] else { continue }
            if found != nil { throw ConfigError.unsupportedTOML("duplicate command") }
            found = try parseString(value)
        }
        return found
    }

    public static func appendServer(to text: String, command: String) throws(ConfigError) -> String {
        let scan = try Scan(text)
        if scan.table != nil { throw ConfigError.unsupportedTOML("remora is already configured") }
        guard !command.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw ConfigError.unsupportedTOML("control character in path")
        }
        let eol = text.range(of: "\r\n") != nil ? "\r\n" : "\n"
        var out = text
        if !out.isEmpty {
            if out.utf8.last != 0x0A { out += eol }
            out += eol
        }
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        out += "[mcp_servers.remora]" + eol + "command = \"" + escaped + "\"" + eol + "args = []" + eol
        return out
    }

    public static func removeServer(from text: String) throws(ConfigError) -> String {
        let scan = try Scan(text)
        guard let table = scan.table else { return text }
        var lines = scan.lines.map(\.raw)
        var start = table.header
        var end = table.end
        func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if end == lines.count {
            // The table ran to the end of the file: keep the final newline, drop the separating blank line.
            if lines.last == "", end - 1 > start { end -= 1 }
            if start > 0, isBlank(lines[start - 1]) { start -= 1 }
        } else {
            // A comment right above the next table belongs to that table.
            while end > start + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).hasPrefix("#") { end -= 1 }
        }
        lines.removeSubrange(start..<end)
        return lines.joined(separator: "\n")
    }

    // MARK: - Scanning

    struct Line {
        let raw: String
        let text: String      // trimmed
        let structural: Bool  // not inside a multi-line string or array
    }

    struct Table { let header: Int; let end: Int }

    struct Scan {
        let lines: [Line]
        let table: Table?

        init(_ text: String) throws(ConfigError) {
            for delimiter in ["\"\"\"", "'''"] where (text.components(separatedBy: delimiter).count - 1) % 2 != 0 {
                throw ConfigError.unsupportedTOML("unterminated multi-line string")
            }
            var parsed: [Line] = []
            var state = ScanState()
            for raw in text.components(separatedBy: "\n") {
                let structural = state.depth == 0 && state.multiline == nil
                parsed.append(Line(raw: raw, text: raw.trimmingCharacters(in: .whitespacesAndNewlines), structural: structural))
                state.consume(raw)
            }
            lines = parsed

            var header: Int?
            var end = parsed.count
            var inServersTable = false
            for (index, line) in parsed.enumerated() where line.structural && !line.text.isEmpty && !line.text.hasPrefix("#") {
                if line.text.hasPrefix("[") {
                    let isArray = line.text.hasPrefix("[[")
                    guard let parts = headerParts(line.text) else { throw ConfigError.unsupportedTOML("unreadable table header") }
                    inServersTable = !isArray && parts == ["mcp_servers"]
                    if header != nil, end == parsed.count { end = index }
                    if parts.count >= 2, parts[0] == "mcp_servers", parts[1] == "remora" {
                        if isArray || parts.count > 2 { throw ConfigError.unsupportedTOML("remora subtable") }
                        if header != nil { throw ConfigError.unsupportedTOML("duplicate remora table") }
                        header = index
                        end = parsed.count
                    }
                    continue
                }
                guard let (key, _) = splitKeyValue(line.text) else { continue }
                if key.first == "mcp_servers" {
                    if key.count == 1 || (key.count >= 2 && key[1] == "remora") {
                        throw ConfigError.unsupportedTOML("mcp_servers defined inline or with dotted keys")
                    }
                }
                if inServersTable, key.first == "remora" { throw ConfigError.unsupportedTOML("remora defined inside [mcp_servers]") }
            }
            table = header.map { Table(header: $0, end: end) }
        }
    }

    /// Tracks multi-line strings and bracket depth across lines, ignoring strings and comments.
    struct ScanState {
        var depth = 0
        var multiline: String?

        mutating func consume(_ line: String) {
            let chars = Array(line.unicodeScalars)
            var i = 0
            while i < chars.count {
                if let delimiter = multiline {
                    if matches(chars, i, delimiter) { multiline = nil; i += 3 } else { i += 1 }
                    continue
                }
                let c = chars[i]
                if c == "#" { return }
                if matches(chars, i, "\"\"\"") { multiline = "\"\"\""; i += 3; continue }
                if matches(chars, i, "'''") { multiline = "'''"; i += 3; continue }
                if c == "\"" {
                    i += 1
                    while i < chars.count, chars[i] != "\"" { i += chars[i] == "\\" ? 2 : 1 }
                    i += 1
                    continue
                }
                if c == "'" {
                    i += 1
                    while i < chars.count, chars[i] != "'" { i += 1 }
                    i += 1
                    continue
                }
                if c == "[" || c == "{" { depth += 1 }
                if c == "]" || c == "}" { depth = max(0, depth - 1) }
                i += 1
            }
        }

        private func matches(_ chars: [Unicode.Scalar], _ i: Int, _ s: String) -> Bool {
            let target = Array(s.unicodeScalars)
            return i + target.count <= chars.count && Array(chars[i..<(i + target.count)]) == target
        }
    }

    /// `[a."b".c]` or `[[a.b]]` to ["a", "b", "c"].
    static func headerParts(_ text: String) -> [String]? {
        var body = Substring(text)
        let open = body.hasPrefix("[[") ? 2 : 1
        body = body.dropFirst(open)
        var chars = Array(body.unicodeScalars)
        var i = 0
        var quote: Unicode.Scalar?
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if c == "\\", q == "\"" { i += 2; continue }
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "]" {
                chars = Array(chars[0..<i])
                var s = String.UnicodeScalarView()
                s.append(contentsOf: chars)
                return splitDotted(String(s))
            }
            i += 1
        }
        return nil
    }

    /// `key = value` to (["key"], "value"); dotted and quoted keys are split into parts.
    static func splitKeyValue(_ text: String) -> ([String], String)? {
        var quote: Unicode.Scalar?
        let chars = Array(text.unicodeScalars)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if c == "\\", q == "\"" { i += 2; continue }
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "=" {
                var k = String.UnicodeScalarView(); k.append(contentsOf: chars[0..<i])
                var v = String.UnicodeScalarView(); v.append(contentsOf: chars[(i + 1)...])
                guard let parts = splitDotted(String(k)) else { return nil }
                return (parts, String(v).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            i += 1
        }
        return nil
    }

    static func splitDotted(_ text: String) -> [String]? {
        var parts: [String] = []
        var current = String.UnicodeScalarView()
        var quote: Unicode.Scalar?
        var quoted = false
        let chars = Array(text.unicodeScalars)
        var i = 0
        func flush() -> Bool {
            let s = String(current).trimmingCharacters(in: .whitespaces)
            current = String.UnicodeScalarView()
            if s.isEmpty && !quoted { return false }
            parts.append(s)
            quoted = false
            return true
        }
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if c == "\\", q == "\"", i + 1 < chars.count { current.append(chars[i + 1]); i += 2; continue }
                if c == q { quote = nil } else { current.append(c) }
            } else if c == "\"" || c == "'" {
                quote = c
                quoted = true
            } else if c == "." {
                if !flush() { return nil }
            } else {
                current.append(c)
            }
            i += 1
        }
        if quote != nil || !flush() { return nil }
        return parts
    }

    /// A basic (`"…"` with `\"` and `\\`) or literal (`'…'`) string, optionally followed by a comment.
    static func parseString(_ value: String) throws(ConfigError) -> String {
        let chars = Array(value.unicodeScalars)
        guard let first = chars.first, first == "\"" || first == "'" else { throw ConfigError.unsupportedTOML("command isn't a string") }
        var out = String.UnicodeScalarView()
        var i = 1
        var closed = false
        while i < chars.count {
            let c = chars[i]
            if c == first { closed = true; i += 1; break }
            if c == "\\", first == "\"" {
                guard i + 1 < chars.count, chars[i + 1] == "\"" || chars[i + 1] == "\\" else {
                    throw ConfigError.unsupportedTOML("unsupported escape")
                }
                out.append(chars[i + 1])
                i += 2
                continue
            }
            out.append(c)
            i += 1
        }
        guard closed else { throw ConfigError.unsupportedTOML("unterminated string") }
        var rest = String.UnicodeScalarView(); rest.append(contentsOf: chars[i...])
        let tail = String(rest).trimmingCharacters(in: .whitespaces)
        guard tail.isEmpty || tail.hasPrefix("#") else { throw ConfigError.unsupportedTOML("unexpected text after string") }
        if first == "\"", String(out).contains("\"\"\"") { throw ConfigError.unsupportedTOML("multi-line string") }
        return String(out)
    }
}
