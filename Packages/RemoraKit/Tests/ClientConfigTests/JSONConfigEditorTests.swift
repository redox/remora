import Foundation
import Testing
@testable import ClientConfig

@Suite struct JSONConfigEditorTests {
    let entry: OrderedJSON = .object([("command", .string("/A/remora-mcp")), ("args", .array([]))])

    @Test func preservesKeyOrderAndNumbers() throws {
        let src = Data(#"{"zeta":1.50,"mcpServers":{"other":{"command":"x"}},"alpha":1e3}"#.utf8)
        let out = String(decoding: try JSONConfigEditor.upsertServer(in: src, entry: entry), as: UTF8.self)
        #expect(out.range(of: "zeta")!.lowerBound < out.range(of: "alpha")!.lowerBound)
        #expect(out.contains("1.50") && out.contains("1e3"))
        #expect(out.range(of: "\"other\"")!.lowerBound < out.range(of: "\"remora\"")!.lowerBound)
        #expect(out.range(of: "mcpServers")!.lowerBound < out.range(of: "alpha")!.lowerBound)
    }

    @Test func replacesExistingEntryInPlace() throws {
        let src = Data(#"{"mcpServers":{"a":{"command":"1"},"remora":{"command":"/Old","args":["x"]},"z":{"command":"2"}}}"#.utf8)
        let out = try JSONConfigEditor.upsertServer(in: src, entry: entry)
        let s = String(decoding: out, as: UTF8.self)
        let a = s.range(of: "\"a\"")!.lowerBound, r = s.range(of: "\"remora\"")!.lowerBound, z = s.range(of: "\"z\"")!.lowerBound
        #expect(a < r && r < z)
        #expect(!s.contains("/Old"))
        #expect(try JSONConfigEditor.server(in: out) == entry)
    }

    @Test func nilOrBlankStartsNewDocument() throws {
        for data in [nil, Data(), Data(" \n\t".utf8)] {
            let out = try JSONConfigEditor.upsertServer(in: data, entry: entry)
            let json = try OrderedJSON.parse(out)
            #expect(json == .object([("mcpServers", .object([("remora", entry)]))]))
        }
    }

    @Test func addsMcpServersWhenMissingAtEnd() throws {
        let out = try JSONConfigEditor.upsertServer(in: Data(#"{"numStartups":3}"#.utf8), entry: entry)
        let json = try OrderedJSON.parse(out)
        #expect(json == .object([("numStartups", .number("3")), ("mcpServers", .object([("remora", entry)]))]))
    }

    @Test func rejectsNonObjectMcpServers() {
        for src in [#"{"mcpServers":[]}"#, #"{"mcpServers":null}"#, "[]", "\"x\""] {
            do {
                _ = try JSONConfigEditor.upsertServer(in: Data(src.utf8), entry: entry)
                Issue.record("expected failure for \(src)")
            } catch {
                guard case .unexpectedShape = error else { Issue.record("wrong error \(error)"); continue }
            }
        }
    }

    @Test func removeLeavesOthers() throws {
        let src = Data(#"{"a":1,"mcpServers":{"x":{"command":"1"},"remora":{"command":"/A"},"y":{"command":"2"}},"b":2}"#.utf8)
        let out = try JSONConfigEditor.removeServer(in: src)
        let json = try OrderedJSON.parse(out)
        #expect(json == (try OrderedJSON.parse(Data(#"{"a":1,"mcpServers":{"x":{"command":"1"},"y":{"command":"2"}},"b":2}"#.utf8))))
    }

    @Test func removeOfMissingEntryIsNoOp() throws {
        let src = Data(#"{"a":1}"#.utf8)
        #expect(try JSONConfigEditor.removeServer(in: src) == src)
    }

    @Test func serverReadsEntry() throws {
        #expect(try JSONConfigEditor.server(in: nil) == nil)
        #expect(try JSONConfigEditor.server(in: Data(#"{"mcpServers":{}}"#.utf8)) == nil)
        #expect(try JSONConfigEditor.server(in: Data(#"{"mcpServers":{"remora":{"command":"/p"}}}"#.utf8)) == .object([("command", .string("/p"))]))
    }

    @Test func refusesCommentedFiles() {
        #expect(throws: ConfigError.self) { try JSONConfigEditor.upsertServer(in: Data("{ // hi\n}".utf8), entry: entry) }
    }

    @Test func keepsDetectedIndent() throws {
        let src = Data("{\n    \"a\": 1\n}\n".utf8)
        let s = String(decoding: try JSONConfigEditor.upsertServer(in: src, entry: entry), as: UTF8.self)
        #expect(s.contains("\n    \"a\": 1,"))
        #expect(s.contains("\n        \"remora\""))
    }
}
