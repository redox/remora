import Foundation
import LLMTestSupport
import Testing
@testable import LLM

@Test func lineSplitterKeepsEmptyLines() {
    var s = LineSplitter()
    var out: [String] = []
    for b in Array("event: a\ndata: x\r\n\n\ndata: tail".utf8) {
        if let line = s.feed(b) { out.append(line) }
    }
    if let rest = s.finish() { out.append(rest) }
    #expect(out == ["event: a", "data: x", "", "", "data: tail"])
}

private func split(_ chunks: [String]) -> [String] {
    var s = LineSplitter()
    var out: [String] = []
    for b in chunks.flatMap({ Array($0.utf8) }) { if let l = s.feed(b) { out.append(l) } }
    if let rest = s.finish() { out.append(rest) }
    return out
}

@Test func lineSplitterTreatsLoneCRAsATerminator() {
    #expect(split(["a\rb\r\rc\r\nd\n"]) == ["a", "b", "", "c", "d"])
}

@Test func lineSplitterHandlesCRLFSplitAcrossChunksAndMultibyteText() {
    // The \r\n pair straddles two chunks; "é" is two bytes.
    var s = LineSplitter()
    var out: [String] = []
    for chunk in [Array("data: caf".utf8), [0xC3], [0xA9, UInt8(ascii: "\r")], [UInt8(ascii: "\n")], Array("x\n".utf8)] {
        for b in chunk { if let l = s.feed(b) { out.append(l) } }
    }
    #expect(out == ["data: café", "x"])
}

@Test func userAgentNamesRemora() {
    #expect(URLSessionTransport.userAgent.hasPrefix("Remora/"))
}

@Test func fakeTransportSplitsLinesLikeTheRealOne() async throws {
    let fake = FakeHTTPTransport()
    fake.enqueue("/v1/responses", .text(200, "data: a\n\ndata: b\n\n"))
    let (response, stream) = try await fake.lines(for: URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!))
    var lines: [String] = []
    for try await l in stream { lines.append(l) }
    #expect(response.statusCode == 200 && lines == ["data: a", "", "data: b", ""])
    #expect(fake.requests.count == 1)
    await #expect(throws: URLError.self) { _ = try await fake.data(for: URLRequest(url: URL(string: "https://x.invalid/unscripted")!)) }
}

@Test func lineSplitterCapsAnUnterminatedLine() {
    var s = LineSplitter()
    let byte = UInt8(ascii: "a")
    for _ in 0..<LineSplitter.maxLineBytes { _ = s.feed(byte) }
    #expect(!s.overflowed)
    _ = s.feed(byte)
    #expect(s.overflowed)
    #expect(s.finish() == nil)
}

@Test func lineSplitterAllowsALongTerminatedLine() {
    var s = LineSplitter()
    var out: [String] = []
    for _ in 0..<(SSEParser.maxEventBytes) { _ = s.feed(UInt8(ascii: "a")) }
    if let l = s.feed(UInt8(ascii: "\n")) { out.append(l) }
    #expect(!s.overflowed && out.count == 1 && out[0].utf8.count == SSEParser.maxEventBytes)
}

@Test func transportSessionKeepsNoCookiesOrCache() {
    // Never `URLSession.shared`: nothing of a request (cookies, cached responses) outlives it.
    let c = URLSessionTransport.sessionConfiguration()
    #expect(c.httpCookieStorage == nil && !c.httpShouldSetCookies && c.httpCookieAcceptPolicy == .never)
    #expect(c.urlCache == nil && c.urlCredentialStorage == nil)
    #expect(c.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
}
