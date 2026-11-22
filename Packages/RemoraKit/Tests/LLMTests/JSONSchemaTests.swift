import Foundation
import Testing
@testable import LLM

@Test func schemaHelperIsStrict() {
    let s = JSONSchema.object(["a": JSONSchema.string()])
    #expect(s == .object([
        "type": .string("object"),
        "properties": .object(["a": .object(["type": .string("string")])]),
        "required": .array([.string("a")]),
        "additionalProperties": .bool(false),
    ]))
}

@Test func requiredKeepsDeclarationOrderAndNestedObjectsAreStrict() {
    let s = JSONSchema.object([
        "zeta": JSONSchema.number,
        "alpha": JSONSchema.array(JSONSchema.object(["n": JSONSchema.integer, "ok": JSONSchema.boolean])),
        "kind": JSONSchema.string(enum: ["a", "b"]),
    ])
    guard case .object(let o) = s, case .object(let props)? = o["properties"] else { Issue.record("shape"); return }
    #expect(o["required"] == .array([.string("zeta"), .string("alpha"), .string("kind")]))
    #expect(props["zeta"] == .object(["type": .string("number")]))
    #expect(props["kind"] == .object(["type": .string("string"), "enum": .array([.string("a"), .string("b")])]))
    guard case .object(let arr)? = props["alpha"], case .object(let item)? = arr["items"] else { Issue.record("array"); return }
    #expect(arr["type"] == .string("array"))
    #expect(arr["maxItems"] == nil)  // F-50: counts are capped in code, never in the schema
    #expect(item["additionalProperties"] == .bool(false))
    #expect(item["required"] == .array([.string("n"), .string("ok")]))
}

@Test func schemaCheckAcceptsAMatchingValueAndRejectsExtras() {
    let s = JSONSchema.object(["name": JSONSchema.string(), "tags": JSONSchema.array(JSONSchema.string(enum: ["x", "y"]))])
    #expect(SchemaCheck.validate(#"{"name":"n","tags":["x"]}"#, against: s))
    #expect(!SchemaCheck.validate(#"{"name":"n","tags":["z"]}"#, against: s))
    #expect(!SchemaCheck.validate(#"{"name":"n","tags":[],"extra":1}"#, against: s))
    #expect(!SchemaCheck.validate(#"{"name":"n"}"#, against: s))
}
