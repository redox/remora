import Foundation

/// Bounded, depth-first text extraction from an `AXNode` tree.
///
/// Secure text fields and noisy chrome (scroll bars, menus) are skipped along
/// with their subtrees. Traversal is iterative so deep trees cannot overflow
/// the stack, and `children` is read only for nodes that will be descended into.
public struct AXTextExtractor: Sendable {
    public let maxDepth: Int
    public let maxNodes: Int
    public let maxChars: Int

    private static let secureRole = "AXSecureTextField"
    private static let skippedRoles: Set<String> = ["AXScrollBar", "AXMenuBar", "AXMenu"]

    public init(maxDepth: Int = 40, maxNodes: Int = 4_000, maxChars: Int = 50_000) {
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
        self.maxChars = maxChars
    }

    public func extract(from root: any AXNode) -> String {
        var lines: [String] = []
        var charCount = 0
        var visited = 0
        var last: String?
        var stack: [(node: any AXNode, depth: Int)] = [(root, 0)]

        traversal: while let (node, depth) = stack.popLast() {
            if visited >= maxNodes { break }
            visited += 1

            let role = node.role
            let subrole = node.subrole
            if role == Self.secureRole || subrole == Self.secureRole { continue }
            if let role, Self.skippedRoles.contains(role) { continue }

            for raw in [node.value, node.title, node.nodeDescription] {
                guard let raw else { continue }
                var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty || text == last { continue }
                let separator = lines.isEmpty ? 0 : 1
                let remaining = maxChars - charCount - separator
                if remaining <= 0 { break traversal }
                if text.count > remaining { text = String(text.prefix(remaining)) }
                lines.append(text)
                charCount += separator + text.count
                last = text
                if charCount >= maxChars { break traversal }
            }

            guard depth < maxDepth, visited < maxNodes else { continue }
            let kids = node.children
            for child in kids.reversed() { stack.append((child, depth + 1)) }
        }
        return lines.joined(separator: "\n")
    }
}
