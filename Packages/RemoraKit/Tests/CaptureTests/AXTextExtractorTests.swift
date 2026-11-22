import Foundation
import Synchronization
import Testing
@testable import Capture

struct FakeAXNode: AXNode {
    var role: String? = nil
    var subrole: String? = nil
    var value: String? = nil
    var title: String? = nil
    var nodeDescription: String? = nil
    var children: [any AXNode] = []
}

/// Counts reads of `children` and of scalar properties; shared across the tree.
final class AccessCounter: Sendable {
    private let state = Mutex<[String: Int]>([:])
    func bump(_ key: String) { state.withLock { $0[key, default: 0] += 1 } }
    func count(_ key: String) -> Int { state.withLock { $0[key] ?? 0 } }
    var maxCount: Int { state.withLock { $0.values.max() ?? 0 } }
}

struct CountingAXNode: AXNode {
    let id: String
    let counter: AccessCounter
    var _role: String? = nil
    var _value: String? = nil
    var _children: [CountingAXNode] = []

    var role: String? { counter.bump("role:\(id)"); return _role }
    var subrole: String? { counter.bump("subrole:\(id)"); return nil }
    var value: String? { counter.bump("value:\(id)"); return _value }
    var title: String? { counter.bump("title:\(id)"); return nil }
    var nodeDescription: String? { counter.bump("desc:\(id)"); return nil }
    var children: [any AXNode] { counter.bump("children:\(id)"); return _children }
}

@Test func extractsTextInDocumentOrder() {
    let tree = FakeAXNode(role: "AXWindow", children: [
        FakeAXNode(role: "AXStaticText", value: "Hello"),
        FakeAXNode(role: "AXGroup", children: [FakeAXNode(role: "AXTextArea", value: "World")]),
    ])
    #expect(AXTextExtractor().extract(from: tree) == "Hello\nWorld")
}

@Test func skipsSecureFields() {
    let byRole = FakeAXNode(role: "AXSecureTextField", value: "hunter2")
    let bySubrole = FakeAXNode(role: "AXTextField", subrole: "AXSecureTextField", value: "hunter3")
    let tree = FakeAXNode(role: "AXWindow", children: [
        byRole, bySubrole, FakeAXNode(role: "AXStaticText", value: "ok"),
    ])
    #expect(AXTextExtractor().extract(from: tree) == "ok")
}

@Test func skipsSecureSubtreeChildren() {
    let secure = FakeAXNode(role: "AXSecureTextField", children: [FakeAXNode(role: "AXStaticText", value: "leak")])
    let tree = FakeAXNode(role: "AXWindow", children: [secure])
    #expect(AXTextExtractor().extract(from: tree) == "")
}

@Test func dedupesAdjacentRepeats() {
    let node = FakeAXNode(role: "AXStaticText", value: "Inbox", title: "Inbox")
    #expect(AXTextExtractor().extract(from: node) == "Inbox")
}

@Test func collectsValueTitleDescriptionTrimmedDroppingEmpty() {
    let node = FakeAXNode(role: "AXButton", value: "  v  ", title: "   ", nodeDescription: "d\n")
    #expect(AXTextExtractor().extract(from: node) == "v\nd")
}

@Test func skipsNoiseRoles() {
    let tree = FakeAXNode(role: "AXWindow", children: [
        FakeAXNode(role: "AXScrollBar", value: "50%"),
        FakeAXNode(role: "AXMenuBar", children: [FakeAXNode(role: "AXMenuItem", title: "File")]),
        FakeAXNode(role: "AXMenu", title: "ctx"),
        FakeAXNode(role: "AXStaticText", value: "body"),
    ])
    #expect(AXTextExtractor().extract(from: tree) == "body")
}

@Test func capsTotalCharacters() {
    let big = FakeAXNode(role: "AXTextArea", value: String(repeating: "a", count: 5_000_000))
    let out = AXTextExtractor(maxChars: 50_000).extract(from: big)
    #expect(out.count == 50_000)
}

@Test func capsTotalCharactersAcrossLines() {
    let tree = FakeAXNode(role: "AXGroup", children: (0..<10).map { i in
        FakeAXNode(role: "AXStaticText", value: String(repeating: "b", count: 30) + "\(i)")
    })
    let out = AXTextExtractor(maxChars: 100).extract(from: tree)
    #expect(out.count == 100)
}

@Test func capsNodeCount() {
    let wide = FakeAXNode(role: "AXGroup", children: (0..<100_000).map { FakeAXNode(role: "AXStaticText", value: "n\($0)") })
    let out = AXTextExtractor(maxNodes: 4_000).extract(from: wide)
    #expect(out.split(separator: "\n").count < 4_000)
}

@Test func capsDepth() {
    var node: any AXNode = FakeAXNode(role: "AXStaticText", value: "deep")
    for _ in 0..<1_000 { node = FakeAXNode(role: "AXGroup", children: [node]) }
    let start = ContinuousClock.now
    let out = AXTextExtractor(maxDepth: 40).extract(from: node)
    #expect(out == "")
    #expect(ContinuousClock.now - start < .seconds(2))
}

@Test func readsChildrenAtMostOncePerNodeAndNeverBeyondMaxDepth() {
    let counter = AccessCounter()
    // chain n0 > n1 > ... > n10, each with text
    var node = CountingAXNode(id: "n10", counter: counter, _role: "AXGroup", _value: "t10")
    for i in stride(from: 9, through: 0, by: -1) {
        node = CountingAXNode(id: "n\(i)", counter: counter, _role: "AXGroup", _value: "t\(i)", _children: [node])
    }
    let out = AXTextExtractor(maxDepth: 3).extract(from: node)
    #expect(out == "t0\nt1\nt2\nt3")
    #expect(counter.maxCount <= 1)
    // depth 3 is visited but its children are never fetched; deeper nodes never touched
    #expect(counter.count("children:n3") == 0)
    for i in 4...10 {
        #expect(counter.count("children:n\(i)") == 0)
        #expect(counter.count("value:n\(i)") == 0)
    }
    for i in 0..<3 { #expect(counter.count("children:n\(i)") == 1) }
}

@Test func doesNotReadChildrenOfSecureOrSkippedNodes() {
    let counter = AccessCounter()
    let secure = CountingAXNode(id: "s", counter: counter, _role: "AXSecureTextField", _value: "pw")
    let bar = CountingAXNode(id: "m", counter: counter, _role: "AXMenuBar")
    let root = CountingAXNode(id: "r", counter: counter, _role: "AXWindow", _children: [secure, bar])
    _ = AXTextExtractor().extract(from: root)
    #expect(counter.count("children:s") == 0)
    #expect(counter.count("children:m") == 0)
    #expect(counter.count("value:s") == 0)
}
