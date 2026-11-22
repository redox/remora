import Foundation

/// A JSON value that remembers key order and the original lexeme of numbers, so that
/// rewriting a config file changes nothing but what the caller edited.
public indirect enum OrderedJSON: Sendable, Equatable {
    case object([(String, OrderedJSON)])
    case array([OrderedJSON])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    public static func == (lhs: OrderedJSON, rhs: OrderedJSON) -> Bool {
        switch (lhs, rhs) {
        case let (.object(a), .object(b)):
            a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case let (.array(a), .array(b)): a == b
        case let (.string(a), .string(b)): a == b
        case let (.number(a), .number(b)): a == b
        case let (.bool(a), .bool(b)): a == b
        case (.null, .null): true
        default: false
        }
    }

    /// Strict RFC 8259 over UTF-8. Rejects a BOM, comments, trailing commas, control
    /// characters in strings, lone surrogates and duplicate keys.
    public static func parse(_ data: Data) throws(ConfigError) -> OrderedJSON {
        var parser = JSONParser(bytes: [UInt8](data))
        return try parser.parseDocument()
    }

    /// `"key": value`, `\n` line ends, a trailing newline, strings escaped minimally.
    public func serialized(indent: Int = 2) -> Data {
        var out = ""
        write(into: &out, indent: max(0, indent), level: 0)
        out.append("\n")
        return Data(out.utf8)
    }

    private func write(into out: inout String, indent: Int, level: Int) {
        switch self {
        case .null: out.append("null")
        case .bool(let b): out.append(b ? "true" : "false")
        case .number(let n): out.append(n)
        case .string(let s): OrderedJSON.escape(s, into: &out)
        case .array(let items):
            if items.isEmpty { out.append("[]"); return }
            out.append("[\n")
            for (i, item) in items.enumerated() {
                out.append(String(repeating: " ", count: indent * (level + 1)))
                item.write(into: &out, indent: indent, level: level + 1)
                out.append(i == items.count - 1 ? "\n" : ",\n")
            }
            out.append(String(repeating: " ", count: indent * level))
            out.append("]")
        case .object(let pairs):
            if pairs.isEmpty { out.append("{}"); return }
            out.append("{\n")
            for (i, pair) in pairs.enumerated() {
                out.append(String(repeating: " ", count: indent * (level + 1)))
                OrderedJSON.escape(pair.0, into: &out)
                out.append(": ")
                pair.1.write(into: &out, indent: indent, level: level + 1)
                out.append(i == pairs.count - 1 ? "\n" : ",\n")
            }
            out.append(String(repeating: " ", count: indent * level))
            out.append("}")
        }
    }

    private static func escape(_ s: String, into out: inout String) {
        out.append("\"")
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            case "\u{08}": out.append("\\b")
            case "\u{0C}": out.append("\\f")
            default:
                if scalar.value < 0x20 {
                    out.append("\\u" + String(format: "%04x", scalar.value))
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out.append("\"")
    }
}

extension OrderedJSON {
    var objectPairs: [(String, OrderedJSON)]? {
        if case .object(let p) = self { return p }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

private struct JSONParser {
    let b: [UInt8]
    var i = 0
    static let maxDepth = 63

    init(bytes: [UInt8]) { b = bytes }

    func fail(_ reason: String) -> ConfigError {
        let end = min(i, b.count)
        var line = 1, column = 1
        for k in 0..<end {
            if b[k] == 0x0A { line += 1; column = 1 } else { column += 1 }
        }
        return .unparseable(line: line, column: column, reason: reason)
    }

    mutating func parseDocument() throws(ConfigError) -> OrderedJSON {
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { throw fail("byte order mark") }
        skipWhitespace()
        let value = try parseValue(depth: 0)
        skipWhitespace()
        if i < b.count { throw fail("unexpected content after the document") }
        return value
    }

    mutating func skipWhitespace() {
        while i < b.count, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D { i += 1 }
    }

    mutating func parseValue(depth: Int) throws(ConfigError) -> OrderedJSON {
        guard depth < JSONParser.maxDepth else { throw fail("nesting too deep") }
        guard i < b.count else { throw fail("unexpected end of file") }
        switch b[i] {
        case UInt8(ascii: "{"): return try parseObject(depth: depth)
        case UInt8(ascii: "["): return try parseArray(depth: depth)
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
        case UInt8(ascii: "/"): throw fail("comments are not allowed")
        default: throw fail("unexpected character")
        }
    }

    mutating func expect(_ word: String) throws(ConfigError) {
        let w = Array(word.utf8)
        guard i + w.count <= b.count, Array(b[i..<(i + w.count)]) == w else { throw fail("invalid literal") }
        i += w.count
    }

    mutating func parseObject(depth: Int) throws(ConfigError) -> OrderedJSON {
        i += 1
        skipWhitespace()
        var pairs: [(String, OrderedJSON)] = []
        var seen = Set<String>()
        if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
        while true {
            guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw fail("expected a key") }
            let key = try parseString()
            if !seen.insert(key).inserted { throw fail("duplicate key") }
            skipWhitespace()
            guard i < b.count, b[i] == UInt8(ascii: ":") else { throw fail("expected ':'") }
            i += 1
            skipWhitespace()
            let value = try parseValue(depth: depth + 1)
            pairs.append((key, value))
            skipWhitespace()
            guard i < b.count else { throw fail("unexpected end of file") }
            if b[i] == UInt8(ascii: ",") { i += 1; skipWhitespace(); continue }
            if b[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
            throw fail("expected ',' or '}'")
        }
    }

    mutating func parseArray(depth: Int) throws(ConfigError) -> OrderedJSON {
        i += 1
        skipWhitespace()
        var items: [OrderedJSON] = []
        if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
        while true {
            items.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            guard i < b.count else { throw fail("unexpected end of file") }
            if b[i] == UInt8(ascii: ",") { i += 1; skipWhitespace(); continue }
            if b[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            throw fail("expected ',' or ']'")
        }
    }

    mutating func parseHex4() throws(ConfigError) -> UInt32 {
        guard i + 4 <= b.count else { throw fail("bad unicode escape") }
        var v: UInt32 = 0
        for _ in 0..<4 {
            let c = b[i]
            let d: UInt32
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): d = UInt32(c - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): d = UInt32(c - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): d = UInt32(c - UInt8(ascii: "A")) + 10
            default: throw fail("bad unicode escape")
            }
            v = v * 16 + d
            i += 1
        }
        return v
    }

    mutating func parseString() throws(ConfigError) -> String {
        i += 1
        var bytes: [UInt8] = []
        while true {
            guard i < b.count else { throw fail("unterminated string") }
            let c = b[i]
            if c == UInt8(ascii: "\"") { i += 1; break }
            if c < 0x20 { throw fail("control character in string") }
            if c != UInt8(ascii: "\\") { bytes.append(c); i += 1; continue }
            i += 1
            guard i < b.count else { throw fail("unterminated string") }
            let e = b[i]
            i += 1
            switch e {
            case UInt8(ascii: "\""): bytes.append(0x22)
            case UInt8(ascii: "\\"): bytes.append(0x5C)
            case UInt8(ascii: "/"): bytes.append(0x2F)
            case UInt8(ascii: "b"): bytes.append(0x08)
            case UInt8(ascii: "f"): bytes.append(0x0C)
            case UInt8(ascii: "n"): bytes.append(0x0A)
            case UInt8(ascii: "r"): bytes.append(0x0D)
            case UInt8(ascii: "t"): bytes.append(0x09)
            case UInt8(ascii: "u"):
                var code = try parseHex4()
                if (0xD800...0xDBFF).contains(code) {
                    guard i + 1 < b.count, b[i] == UInt8(ascii: "\\"), b[i + 1] == UInt8(ascii: "u") else { throw fail("lone surrogate") }
                    i += 2
                    let low = try parseHex4()
                    guard (0xDC00...0xDFFF).contains(low) else { throw fail("lone surrogate") }
                    code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                } else if (0xDC00...0xDFFF).contains(code) {
                    throw fail("lone surrogate")
                }
                guard let scalar = Unicode.Scalar(code) else { throw fail("bad unicode escape") }
                bytes.append(contentsOf: Array(String(Character(scalar)).utf8))
            default: throw fail("invalid escape")
            }
        }
        guard let s = String(validating: bytes, as: UTF8.self) else { throw fail("invalid UTF-8") }
        return s
    }

    mutating func parseNumber() throws(ConfigError) -> OrderedJSON {
        let start = i
        if b[i] == UInt8(ascii: "-") { i += 1 }
        guard i < b.count else { throw fail("invalid number") }
        if b[i] == UInt8(ascii: "0") {
            i += 1
        } else if (UInt8(ascii: "1")...UInt8(ascii: "9")).contains(b[i]) {
            while i < b.count, isDigit(b[i]) { i += 1 }
        } else {
            throw fail("invalid number")
        }
        if i < b.count, b[i] == UInt8(ascii: ".") {
            i += 1
            guard i < b.count, isDigit(b[i]) else { throw fail("invalid number") }
            while i < b.count, isDigit(b[i]) { i += 1 }
        }
        if i < b.count, b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") {
            i += 1
            if i < b.count, b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") { i += 1 }
            guard i < b.count, isDigit(b[i]) else { throw fail("invalid number") }
            while i < b.count, isDigit(b[i]) { i += 1 }
        }
        return .number(String(decoding: b[start..<i], as: UTF8.self))
    }

    func isDigit(_ c: UInt8) -> Bool { c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") }
}
