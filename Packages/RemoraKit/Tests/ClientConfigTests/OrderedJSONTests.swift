import Foundation
import Testing
@testable import ClientConfig

@Suite struct OrderedJSONTests {
    @Test(arguments: ["{\n // c\n\"a\":1}", "{\"a\":1,}", "\u{FEFF}{}", "{\"a\":1} x", "", "{\"a\":\"\u{1}\"}", "{'a':1}", "[1,]", "{\"a\":01}", "{\"a\":.5}", "{\"a\":\"\\ud800\"}", "/* x */{}"])
    func refusesNonStrictJSON(_ s: String) {
        #expect(throws: ConfigError.self) { try OrderedJSON.parse(Data(s.utf8)) }
    }

    @Test func refusesDuplicateKeys() {
        #expect(throws: ConfigError.self) { try OrderedJSON.parse(Data(#"{"a":1,"a":2}"#.utf8)) }
        #expect(throws: ConfigError.self) { try OrderedJSON.parse(Data(#"{"x":{"a":1,"b":2,"a":3}}"#.utf8)) }
    }

    @Test func errorReportsLineAndColumn() {
        do {
            _ = try OrderedJSON.parse(Data("{\n  \"a\": 1,\n  \"b\": ,\n}".utf8))
            Issue.record("expected failure")
        } catch {
            guard case .unparseable(let line, let column, _) = error else { Issue.record("wrong error \(error)"); return }
            #expect(line == 3)
            #expect(column == 8)
        }
    }

    @Test func keepsNumberLexemesAndOrder() throws {
        let src = #"{"z":1.50,"a":1e3,"m":-0.0,"b":[1,2.0E+2]}"#
        let json = try OrderedJSON.parse(Data(src.utf8))
        let out = String(decoding: json.serialized(), as: UTF8.self)
        #expect(out.contains("1.50") && out.contains("1e3") && out.contains("-0.0") && out.contains("2.0E+2"))
        #expect(out.range(of: "\"z\"")!.lowerBound < out.range(of: "\"a\"")!.lowerBound)
        #expect(out.range(of: "\"a\"")!.lowerBound < out.range(of: "\"m\"")!.lowerBound)
    }

    @Test func serializesWithTwoSpaceIndentAndTrailingNewline() throws {
        let json = try OrderedJSON.parse(Data(#"{"a":{"b":[1,{"c":null}],"e":{},"f":[]},"d":true}"#.utf8))
        let expected = """
        {
          "a": {
            "b": [
              1,
              {
                "c": null
              }
            ],
            "e": {},
            "f": []
          },
          "d": true
        }

        """
        #expect(String(decoding: json.serialized(), as: UTF8.self) == expected)
    }

    @Test func stringsAreEscapedMinimally() throws {
        let json = try OrderedJSON.parse(Data(#"{"k":"a\/b \u00e9 \"q\" \\ \n \u0001 😀 \ud83d\ude00"}"#.utf8))
        let out = String(decoding: json.serialized(indent: 2), as: UTF8.self)
        #expect(out.contains(#""a/b é \"q\" \\ \n \u0001 😀 😀""#))
    }

    @Test func roundTripsThroughSerialization() throws {
        let src = #"{"a":[1,2,{"b":"c\td"}],"é":null,"x":false,"n":12345678901234567890}"#
        let json = try OrderedJSON.parse(Data(src.utf8))
        #expect(try OrderedJSON.parse(json.serialized()) == json)
    }

    @Test func equalityIsOrderSensitive() throws {
        let a = try OrderedJSON.parse(Data(#"{"a":1,"b":2}"#.utf8))
        let b = try OrderedJSON.parse(Data(#"{"b":2,"a":1}"#.utf8))
        #expect(a != b)
    }

    @Test func rejectsAbsurdNesting() {
        let deep = String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)
        #expect(throws: ConfigError.self) { try OrderedJSON.parse(Data(deep.utf8)) }
    }
}
