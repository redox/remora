@testable import Capture
import Foundation
import Testing
@testable import Input

private func field(role: String, page: URL? = nil, selection: NSRange? = nil,
                   selectedText: String? = nil, value: String? = nil) -> FocusedField {
    FocusedField(handle: FakeField(value: value), value: value, selection: selection,
                 selectedText: selectedText, placeholder: nil, role: role, isSecure: false,
                 frame: nil, caretRect: nil, app: "Example",
                 bundleID: page == nil ? "example.editor" : "com.apple.Safari",
                 bundleURL: nil, isWebBacked: page != nil, windowIdentity: 7, selectionPageURL: page)
}

private func source(page: URL? = nil, window: Int? = 7) -> FrontmostWindowReader.ContextSample {
    FrontmostWindowReader.ContextSample(context: WindowContext(
        app: "Example", bundleID: page == nil ? "example.editor" : "com.apple.Safari", url: page),
        identity: ContextIdentity(pid: 42, window: window, windowTitle: nil, url: page, isPrivateBrowsing: false))
}

@Test func aReadOnlyWebAreaCanExposeSelectedTextWithoutAnEditableRange() throws {
    let page = try #require(URL(string: "https://example.com/chat"))
    let selection = field(role: "AXWebArea", page: page, selection: NSRange(location: 0, length: 0),
                          selectedText: "A selected chat message")
    #expect(selection.verifiedExcerpt(in: source(page: page)) == "A selected chat message")
}

@Test func anUnverifiedSelectionCannotPrefillTheNote() {
    let selection = field(role: "AXTextArea", selection: NSRange(location: 0, length: 7), value: "Excerpt only")
    #expect(selection.verifiedExcerpt(in: source(window: 8)) == nil)
    #expect(selection.verifiedExcerpt(in: source()) == "Excerpt")
    let caret = field(role: "AXTextArea", selection: NSRange(location: 0, length: 0), value: "Full text")
    #expect(caret.verifiedExcerpt(in: source()) == nil)
}

@Test func aDifferentWebAreaCannotPrefillTheNote() throws {
    let page = try #require(URL(string: "https://example.com/chat"))
    let selection = field(role: "AXWebArea", page: page, selectedText: "A selected chat message")
    let other = try #require(URL(string: "https://example.com/sidebar"))
    #expect(selection.verifiedExcerpt(in: source(page: other)) == nil)
}
