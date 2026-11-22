import Foundation
import LLM
import MCP
import Testing
@testable import Assistant

@Suite struct ValueBridgeTests {
    @Test func bridgesNestedSchema() {
        let schema: MCP.Value = .object(["type": "object", "properties": .object(["limit": .object(["type": "integer"])]),
                                         "required": .array([.string("limit")])])
        let expected: LLM.JSONValue = .object(["type": .string("object"),
                                               "properties": .object(["limit": .object(["type": .string("integer")])]),
                                               "required": .array([.string("limit")])])
        #expect(ValueBridge.toLLM(schema) == expected)
    }

    @Test func bridgesScalars() {
        #expect(ValueBridge.toLLM(.int(5)) == .number(5))
        #expect(ValueBridge.toLLM(.double(1.5)) == .number(1.5))
        #expect(ValueBridge.toLLM(.bool(true)) == .bool(true))
        #expect(ValueBridge.toLLM(.null) == .null)
        #expect(ValueBridge.toLLM(.array([.int(1), .string("a")])) == .array([.number(1), .string("a")]))
    }

    @Test func argumentsParse() throws {
        #expect(try ValueBridge.arguments(#"{"query":"Oslo","limit":5}"#)["limit"] == .int(5))
        #expect(try ValueBridge.arguments(#"{"query":"Oslo","limit":5}"#)["query"] == .string("Oslo"))
        #expect(try ValueBridge.arguments("").isEmpty)
        #expect(try ValueBridge.arguments("  ").isEmpty)
        #expect(try ValueBridge.arguments("{}").isEmpty)
        #expect(throws: (any Error).self) { try ValueBridge.arguments("[1]") }
        #expect(throws: (any Error).self) { try ValueBridge.arguments("not json") }
    }

    @Test func argumentsKeepTypes() throws {
        let a = try ValueBridge.arguments(#"{"ids":[1,2],"f":1.5,"b":true,"n":null,"o":{"k":"v"}}"#)
        #expect(a["ids"] == .array([.int(1), .int(2)]))
        #expect(a["f"] == .double(1.5))
        #expect(a["b"] == .bool(true))
        #expect(a["n"] == .null)
        #expect(a["o"] == .object(["k": .string("v")]))
    }

    @Test func integralDoublesBecomeInts() throws {
        let a = try ValueBridge.arguments(#"{"limit":5.0,"from":1700000000.0,"neg":-3.0,"f":2.5}"#)
        #expect(a["limit"] == .int(5) && a["from"] == .int(1_700_000_000) && a["neg"] == .int(-3))
        #expect(a["f"] == .double(2.5))
    }

    /// A string that happens to look like a data URL stays a string (the MCP decoder would turn it
    /// into `.data`, which the tools' string arguments reject).
    @Test func dataURLStringsStayStrings() throws {
        #expect(try ValueBridge.arguments(#"{"query":"data:text/plain;base64,SGk="}"#)["query"]
            == .string("data:text/plain;base64,SGk="))
    }
}
