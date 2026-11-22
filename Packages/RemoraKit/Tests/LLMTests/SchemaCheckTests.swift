import Foundation
import Testing
@testable import LLM

private let schema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object(["a": .object(["type": .string("string")])]),
    "required": .array([.string("a")]),
    "additionalProperties": .bool(false),
])

@Test func schemaCheck() {
    #expect(SchemaCheck.validate(#"{"a":"x"}"#, against: schema))
    #expect(!SchemaCheck.validate(#"{"a":1}"#, against: schema))
    #expect(!SchemaCheck.validate(#"{}"#, against: schema))
    #expect(!SchemaCheck.validate(#"{"a":"x","b":2}"#, against: schema))
    #expect(!SchemaCheck.validate("not json", against: schema))
    #expect(SchemaCheck.validate("```json\n{\"a\":\"x\"}\n```", against: schema))
}

@Test func schemaCheckTypesItemsAndEnum() {
    let arr: JSONValue = .object(["type": .string("array"), "items": .object(["type": .string("integer")])])
    #expect(SchemaCheck.validate("[1, 2, 3]", against: arr))
    #expect(!SchemaCheck.validate("[1, 2.5]", against: arr))
    #expect(!SchemaCheck.validate("[true]", against: arr))
    let en: JSONValue = .object(["enum": .array([.string("a"), .string("b")])])
    #expect(SchemaCheck.validate(#""a""#, against: en) && !SchemaCheck.validate(#""c""#, against: en))
    let multi: JSONValue = .object(["type": .array([.string("string"), .string("null")])])
    #expect(SchemaCheck.validate("null", against: multi) && !SchemaCheck.validate("1", against: multi))
}
