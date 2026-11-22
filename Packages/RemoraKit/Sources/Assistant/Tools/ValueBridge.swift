import Foundation
import LLM
import MCP

/// Converts between the MCP server's values (`MCP.Value`, with integers) and the LLM layer's
/// (`LLM.JSONValue`, numbers only). Both modules name a type `JSONValue`: always qualify.
public enum ValueBridge {
    public struct NotAnObject: Error, Equatable, LocalizedError {
        public var errorDescription: String? { "Arguments must be a JSON object." }
    }

    /// An MCP value as an LLM value: integers become numbers, data becomes its data-URL string.
    public static func toLLM(_ v: MCP.Value) -> LLM.JSONValue {
        switch v {
        case .null: .null
        case .bool(let b): .bool(b)
        case .int(let i): .number(Double(i))
        case .double(let d): .number(d)
        case .string(let s): .string(s)
        case .data(let mime, let data): .string(data.dataURLEncoded(mimeType: mime))
        case .array(let a): .array(a.map(toLLM))
        case .object(let o): .object(o.mapValues(toLLM))
        }
    }

    /// A function call's JSON arguments as MCP values. Empty (or blank) text and `{}` give `[:]`;
    /// anything but a JSON object throws. Integral numbers (`5` and `5.0`) become `.int`, and
    /// strings stay strings (no data-URL decoding).
    public static func arguments(_ json: String) throws -> [String: MCP.Value] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [:] }
        let parsed = try JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed])
        guard let object = parsed as? [String: Any] else { throw NotAnObject() }
        return object.mapValues(value)
    }

    private static func value(_ any: Any) -> MCP.Value {
        switch any {
        case is NSNull: return .null
        case let s as String: return .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            if CFNumberIsFloatType(n) {
                // 5.0 means 5: the tools take integers (ids, limits, Unix seconds).
                let d = n.doubleValue
                if d.isFinite, d == d.rounded(), d.magnitude < 1e15 { return .int(Int(d)) }
                return .double(d)
            }
            return .int(n.intValue)
        case let a as [Any]: return .array(a.map(value))
        case let o as [String: Any]: return .object(o.mapValues(value))
        default: return .null
        }
    }
}
