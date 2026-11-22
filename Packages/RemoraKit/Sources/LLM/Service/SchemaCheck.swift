import Foundation

/// A small JSON Schema subset check for on-device output: `type`, `properties`, `required`,
/// `additionalProperties: false`, `items` and `enum`.
public enum SchemaCheck {
    public static func validate(_ text: String, against schema: JSONValue) -> Bool {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(stripFence(text).utf8)) else { return false }
        return check(value, schema)
    }

    static func stripFence(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("```") else { return s }
        if let nl = s.firstIndex(of: "\n") { s = String(s[s.index(after: nl)...]) } else { return s }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix("```") { s.removeLast(3) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func check(_ v: JSONValue, _ schema: JSONValue) -> Bool {
        guard case .object(let s) = schema else { return true }
        if let t = s["type"] {
            let names: [String]
            switch t {
            case .string(let n): names = [n]
            case .array(let a): names = a.compactMap { if case .string(let n) = $0 { n } else { nil } }
            default: names = []
            }
            if !names.isEmpty, !names.contains(where: { matches(v, $0) }) { return false }
        }
        if case .array(let allowed)? = s["enum"], !allowed.contains(v) { return false }
        switch v {
        case .object(let o):
            if case .array(let req)? = s["required"] {
                for case .string(let k) in req where o[k] == nil { return false }
            }
            let props: [String: JSONValue]
            if case .object(let p)? = s["properties"] { props = p } else { props = [:] }
            for (k, sub) in props { if let child = o[k], !check(child, sub) { return false } }
            if case .bool(false)? = s["additionalProperties"], o.keys.contains(where: { props[$0] == nil }) { return false }
        case .array(let a):
            if let items = s["items"] { for e in a where !check(e, items) { return false } }
        default: break
        }
        return true
    }

    private static func matches(_ v: JSONValue, _ type: String) -> Bool {
        switch (type, v) {
        case ("object", .object), ("array", .array), ("string", .string), ("number", .number),
             ("boolean", .bool), ("null", .null): return true
        case ("integer", .number(let n)): return n.isFinite && n == n.rounded()
        default: return false
        }
    }
}
