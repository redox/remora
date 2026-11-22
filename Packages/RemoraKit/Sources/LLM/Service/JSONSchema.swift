import Foundation

/// Builders for strict structured-output schemas (`TextFormat.jsonSchema(…, strict: true)`):
/// every object property is required and `additionalProperties` is false; there are no union
/// or nullable types, so an absent value is `""` or `[]`. Array lengths are never limited in
/// the schema (strict-mode support for `maxItems` is unverified on SIWC, F-50): callers cap
/// counts in code.
public enum JSONSchema {
    /// `required` lists the properties in declaration order.
    public static func object(_ props: KeyValuePairs<String, JSONValue>) -> JSONValue {
        var properties: [String: JSONValue] = [:]
        for (name, schema) in props { properties[name] = schema }
        return .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(props.map { .string($0.key) }),
            "additionalProperties": .bool(false),
        ])
    }

    public static func array(_ items: JSONValue) -> JSONValue {
        .object(["type": .string("array"), "items": items])
    }

    public static func string(enum values: [String]? = nil) -> JSONValue {
        guard let values else { return .object(["type": .string("string")]) }
        return .object(["type": .string("string"), "enum": .array(values.map(JSONValue.string))])
    }

    public static let number: JSONValue = .object(["type": .string("number")])
    public static let integer: JSONValue = .object(["type": .string("integer")])
    public static let boolean: JSONValue = .object(["type": .string("boolean")])
}
