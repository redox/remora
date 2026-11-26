import Foundation

/// Only read text below an explicitly named captions region. A speaker and the utterance
/// must share a row; carrying the previous row's name forward could misattribute speech.
enum MeetingCaptionReader {
    static func isRegion(_ node: any AXNode) -> Bool {
        guard let role = node.role, ["AXGroup", "AXList", "AXScrollArea"].contains(role) else { return false }
        let names = ["captions", "live captions", "closed caption", "closed captions", "sous-titres", "sous-titres en direct"]
        return [node.title, node.nodeDescription].compactMap { $0 }.contains { names.contains(BrowserCatalog.fold($0)) }
    }

    static func read(region: any AXNode, deadline: ContinuousClock.Instant? = nil) -> [MeetingCaption] {
        func hasTime() -> Bool { deadline.map { ContinuousClock.now < $0 } ?? true }
        guard hasTime(), isRegion(region) else { return [] }
        var budget = 96
        var captions: [MeetingCaption] = []
        func text(_ node: any AXNode) -> String? {
            guard hasTime(), node.role == "AXStaticText" else { return nil }
            let raw = node.value ?? node.title ?? ""
            let trimmed = String(raw.prefix(1500)).trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        func visit(_ node: any AXNode, depth: Int) {
            guard hasTime(), depth < 8, budget > 0, let role = node.role,
                  ["AXGroup", "AXList", "AXScrollArea", "AXRow"].contains(role) else { return }
            let children = Array(node.children.prefix(24))
            budget -= 1 + children.count
            guard budget >= 0 else { return }
            var speaker: String?
            var lines: [String] = []
            for child in children {
                guard hasTime() else { return }
                if let value = text(child) {
                    let label = BrowserCatalog.fold(child.nodeDescription ?? "")
                    if ["speaker", "speaker name", "intervenant", "locuteur"].contains(label) {
                        guard speaker == nil else { return }
                        speaker = value
                    } else {
                        lines.append(value)
                    }
                } else if child.role == "AXGroup" {
                    let fields = Array(child.children.prefix(8))
                    budget -= fields.count
                    guard budget >= 0 else { return }
                    let names = fields.compactMap(text)
                    if fields.contains(where: { $0.role == "AXImage" }), names.count == 1 {
                        guard speaker == nil else { return }
                        speaker = names[0]
                    } else if fields.count == 1, let value = names.first {
                        lines.append(value)
                    }
                }
            }
            if let speaker, speaker.count <= 120, !lines.isEmpty {
                captions.append(MeetingCaption(text: String(lines.joined(separator: " ").prefix(1500)), speaker: speaker))
                return
            }
            for child in children { visit(child, depth: depth + 1) }
        }
        visit(region, depth: 0)
        return hasTime() ? captions : []
    }
}
