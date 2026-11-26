import AppKit
import Testing
import Foundation
@testable import ChatBar

@Test func parsesBlocks() {
    #expect(MarkdownBlocks.parse("# T\nHello\nworld\n\n- a\n  - b\n1. c\n```swift\nx\n```") == [.heading(level: 1, text: "T"), .paragraph("Hello\nworld"), .bullet(depth: 0, text: "a"), .bullet(depth: 1, text: "b"), .numbered(number: 1, text: "c"), .code(language: "swift", text: "x", closed: true)])
}
@Test func parsesQuoteAndRule() {
    #expect(MarkdownBlocks.parse("> hi\n> there\n---\n* x\n+ y") == [.quote("hi\nthere"), .rule, .bullet(depth: 0, text: "x"), .bullet(depth: 0, text: "y")])
}
@Test func unclosedFenceDuringStreamingKeepsText() {
    #expect(MarkdownBlocks.parse("Run:\n```\nmake te") == [.paragraph("Run:"), .code(language: nil, text: "make te", closed: false)])
}
@Test(arguments: [("[x](https://a.b)", true), ("[x](mailto:a@b.c)", true), ("[x](javascript:alert(1))", false), ("[x](file:///etc/passwd)", false), ("[x](remora://settings)", false)])
func onlyWebLinksAreClickable(md: String, clickable: Bool) {
    #expect(MarkdownBlocks.inline(md).runs.contains { $0.link != nil } == clickable)
    #expect(String(MarkdownBlocks.inline(md).characters) == "x")
}

@Test func crlfDocumentSplitsIntoBlocks() {
    #expect(MarkdownBlocks.parse("# T\r\nHello\r\n\r\n- a\r\n```swift\r\nx\r\n```\r\nend") == [.heading(level: 1, text: "T"), .paragraph("Hello"), .bullet(depth: 0, text: "a"), .code(language: "swift", text: "x", closed: true), .paragraph("end")])
}
@Test func inlineImageNeverKeepsRemoteURL() {
    let a = MarkdownBlocks.inline("![alt](https://evil/x.png)")
    #expect(!a.runs.contains { $0.imageURL != nil })
    #expect(!a.runs.contains { $0.link != nil })
}
@Test func bulletDepthIsCapped() {
    #expect(MarkdownBlocks.parse(String(repeating: " ", count: 60) + "- deep") == [.bullet(depth: 6, text: "deep")])
}
@Test func inlineTripleBacktickLineIsNotAFence() {
    #expect(MarkdownBlocks.parse("```code```") == [.paragraph("```code```")])
}
@Test func longLanguageIsCapped() {
    let blocks = MarkdownBlocks.parse("```" + String(repeating: "a", count: 100) + "\nx\n```")
    #expect(blocks == [.code(language: String(repeating: "a", count: 32), text: "x", closed: true)])
}
@Test func hugeInputIsTruncatedWithMarker() {
    let blocks = MarkdownBlocks.parse(String(repeating: "a", count: 250_000))
    #expect(blocks.count == 2)
    #expect(blocks.last == .paragraph("[… truncated]"))
    if case .paragraph(let t) = blocks[0] { #expect(t.count == 200_000) } else { Issue.record("expected paragraph") }
}

@MainActor @Test func chatProseIsSelectableAcrossBlocksAndKeepsCodeSeparate() throws {
    let markdown = "# Title\n\n**Hello**\n\n- first\n2. second\n```swift\nlet value = 1\n```\nDone"
    let sections = ChatMarkdown(fontSize: 13).sections(markdown)
    try #require(sections.count == 3)
    guard case .prose(let body) = sections[0], case .code(let language, let code) = sections[1],
          case .prose(let end) = sections[2] else {
        Issue.record("Expected prose around a copyable code block")
        return
    }
    #expect(body.string == "Title\nHello\n•  first\n2.  second")
    #expect(language == "swift" && code == "let value = 1")
    #expect(end.string == "Done")
}

@MainActor @Test func selectableChatLinksRevealTheirDestinationAndKeepTheSchemeFilter() throws {
    let sections = ChatMarkdown(fontSize: 13).sections("[web](https://example.com) [blocked](file:///tmp/example)")
    guard case .prose(let text) = try #require(sections.first) else {
        Issue.record("Expected a paragraph")
        return
    }
    #expect(text.attribute(.link, at: 0, effectiveRange: nil) as? URL == URL(string: "https://example.com"))
    #expect(text.attribute(.toolTip, at: 0, effectiveRange: nil) as? String == "https://example.com")
    #expect(text.attribute(.link, at: 4, effectiveRange: nil) == nil)
}
