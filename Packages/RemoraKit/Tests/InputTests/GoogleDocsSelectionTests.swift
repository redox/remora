import Foundation
import Testing
@testable import Input

private let page = URL(string: "https://docs.google.com/document/d/example/edit")!

@Test func docsCopyUsesOnlyFreshTextFromTheExpectedDocumentAndRestoresTheClipboard() {
    let board = FakePasteboard(items: [[PasteboardEntry(type: "public.png", data: Data([1, 2]))]])
    let before = board.snapshot()
    let result = GoogleDocsSelection.copy(from: page, board: board, sourceURL: { page },
        copiedText: { "A selected passage" }, stillSelected: { true }, sendCopy: {
            _ = board.write(text: "A selected passage")
            return true
        }, timeout: .zero)
    #expect(result == "A selected passage")
    #expect(board.snapshot() == before)
}

@Test(arguments: [true, false])
func docsCopyIgnoresAStaleClipboardOrAnotherDocument(stale: Bool) {
    let board = FakePasteboard(items: [[PasteboardEntry(type: "public.png", data: Data([1, 2]))]])
    let before = board.snapshot()
    let other = URL(string: "https://docs.google.com/document/d/other/edit")!
    let result = GoogleDocsSelection.copy(from: page, board: board, sourceURL: { stale ? page : other },
        copiedText: { Issue.record("Read an unrelated clipboard"); return nil }, stillSelected: { true }, sendCopy: {
            if !stale { _ = board.write(text: "An unrelated copy") }
            return true
        }, timeout: .zero)
    #expect(result == nil)
    #expect((board.snapshot() == before) == stale)
}

@Test func docsCopyLeavesANewerClipboardItemAlone() {
    let board = FakePasteboard(items: [])
    let result = GoogleDocsSelection.copy(from: page, board: board, sourceURL: { page }, copiedText: {
        board.userCopy("A newer copy")
        return "The passage"
    }, stillSelected: { true }, sendCopy: {
        board.userCopy("The passage")
        return true
    }, timeout: .zero)
    #expect(result == nil)
    #expect(board.restores == 0)
}
