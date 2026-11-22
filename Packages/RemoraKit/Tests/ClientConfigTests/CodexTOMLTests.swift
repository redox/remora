import Foundation
import Testing
@testable import ClientConfig

@Suite struct CodexTOMLTests {
    @Test func codexAppendAndRead() throws {
        let base = "model = \"o\"\n\n[mcp_servers.x]\ncommand = \"/x\"\n"
        let out = try CodexTOML.appendServer(to: base, command: "/P/remora-mcp")
        #expect(out.hasPrefix(base))
        #expect(out.hasSuffix("\n[mcp_servers.remora]\ncommand = \"/P/remora-mcp\"\nargs = []\n"))
        #expect(try CodexTOML.serverCommand(in: out) == "/P/remora-mcp")
        #expect(out.contains("[mcp_servers.x]\ncommand = \"/x\""))
    }

    @Test func appendAddsNewlineWhenMissing() throws {
        let out = try CodexTOML.appendServer(to: "a = 1", command: "/p")
        #expect(out == "a = 1\n\n[mcp_servers.remora]\ncommand = \"/p\"\nargs = []\n")
    }

    @Test func appendToEmptyHasNoLeadingBlankLine() throws {
        #expect(try CodexTOML.appendServer(to: "", command: "/p") == "[mcp_servers.remora]\ncommand = \"/p\"\nargs = []\n")
    }

    @Test(arguments: [
        "a = \"\"\"\nmulti\n",
        "a = '''\nmulti\n",
        "mcp_servers = { remora = { command = \"x\" } }",
        "mcp_servers.remora.command = \"x\"",
        "[mcp_servers.remora.env]\nA=1",
        "[mcp_servers.\"remora\".env]\nA=1",
        "[mcp_servers]\nremora = { command = \"x\" }\n",
        "[mcp_servers.remora]\ncommand = \"/already\"\n",
    ])
    func codexRefusesUnsafeShapes(_ t: String) {
        #expect(throws: ConfigError.self) { try CodexTOML.appendServer(to: t, command: "/p") }
    }

    @Test func codexEscapesQuotesInPath() throws {
        let path = #"/Ap"p/back\slash/remora-mcp"#
        let out = try CodexTOML.appendServer(to: "", command: path)
        #expect(out.contains(#"command = "/Ap\"p/back\\slash/remora-mcp""#))
        #expect(try CodexTOML.serverCommand(in: out) == path)
    }

    @Test func refusesControlCharactersInPath() {
        #expect(throws: ConfigError.self) { try CodexTOML.appendServer(to: "", command: "/a\nb") }
    }

    @Test func readsQuotedHeaderAndComments() throws {
        let t = "[mcp_servers.\"remora\"] # mine\nargs = []\ncommand = \"/q\" # c\n[other]\ncommand = \"/no\"\n"
        #expect(try CodexTOML.serverCommand(in: t) == "/q")
    }

    @Test func readsLiteralStringCommand() throws {
        #expect(try CodexTOML.serverCommand(in: "[mcp_servers.remora]\ncommand = '/lit\\eral'\n") == "/lit\\eral")
    }

    @Test func absentServerIsNil() throws {
        #expect(try CodexTOML.serverCommand(in: "a = 1\n[mcp_servers.x]\ncommand = \"/x\"\n") == nil)
    }

    @Test func headerLookalikesInStringsAndArraysAreIgnored() throws {
        let t = "a = \"\"\"\n[mcp_servers.remora]\ncommand = \"/fake\"\n\"\"\"\nb = [\n  [1],\n  [2]\n]\n"
        #expect(try CodexTOML.serverCommand(in: t) == nil)
        let out = try CodexTOML.appendServer(to: t, command: "/real")
        #expect(try CodexTOML.serverCommand(in: out) == "/real")
    }

    @Test func removeDeletesOnlyOurTable() throws {
        let t = "m = 1\n\n[mcp_servers.remora]\ncommand = \"/p\"\nargs = []\n\n[mcp_servers.x]\ncommand = \"/x\"\n"
        let out = try CodexTOML.removeServer(from: t)
        #expect(out == "m = 1\n\n[mcp_servers.x]\ncommand = \"/x\"\n")
    }

    @Test func appendThenRemoveRoundTrips() throws {
        let base = "model = \"o\"\n\n[tui]\nx = 1\n"
        let added = try CodexTOML.appendServer(to: base, command: "/p")
        #expect(try CodexTOML.removeServer(from: added) == base)
    }

    @Test func removeWithoutServerIsIdentity() throws {
        let t = "a = 1\n"
        #expect(try CodexTOML.removeServer(from: t) == t)
    }

    @Test func crlfFilesStayCRLF() throws {
        let out = try CodexTOML.appendServer(to: "a = 1\r\n", command: "/p")
        #expect(out == "a = 1\r\n\r\n[mcp_servers.remora]\r\ncommand = \"/p\"\r\nargs = []\r\n")
        #expect(try CodexTOML.serverCommand(in: out) == "/p")
    }
}
