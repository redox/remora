import Foundation
import MCP

/// Quill can return a ToolResponse document as an MCP text block.
enum QuillMeetingText {
    static func decode(_ text: String) throws -> Value? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("<ToolResponse") else { return nil }
        guard !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY") else {
            throw MeetingImportError.invalidResponse
        }
        let parser = XMLParser(data: Data(text.utf8))
        let collector = Collector()
        parser.delegate = collector
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = collector.root, root.name == "ToolResponse" else {
            throw MeetingImportError.invalidResponse
        }

        let container = root.children.first { ["meetings", "results"].contains($0.name) }
        let meetings = (container ?? root).children.filter { $0.name == "meeting" }
        if container != nil || !meetings.isEmpty {
            var result: [String: Value] = ["meetings": .array(meetings.map { .object($0.fields) })]
            if let attrs = container?.attributes, let total = attrs["count"].flatMap(Int.init) {
                let offset = attrs["offset"].flatMap(Int.init) ?? 0
                result["has_more"] = .bool(total > offset && total - offset > meetings.count)
            }
            return .object(result)
        }
        if let transcript = root.children.first(where: { $0.name == "transcript" && !$0.isPrivate }) {
            let segments = transcript.children.filter { ["segment", "utterance"].contains($0.name) && !$0.isPrivate }
            return .object(["transcript": segments.isEmpty ? .string(transcript.text) :
                .array(segments.map { .object(["speaker": .string($0.attributes["speaker"] ?? ""),
                                             "text": .string($0.text)]) })])
        }
        if let minutes = root.children.first(where: { ["minutes", "summary"].contains($0.name) }),
           !minutes.isPrivate {
            return .object(["minutes": .string(minutes.text)])
        }
        if let notes = root.children.first(where: { $0.name == "notes" && !$0.isPrivate }) {
            let content = notes.children.filter { $0.name == "note" && !$0.isPrivate }.compactMap { note in
                note.children.first { ["markdown", "content", "text"].contains($0.name) }?.text
            }
            return .object(["minutes": .string(content.joined(separator: "\n\n"))])
        }
        if root.children.isEmpty && root.text.isEmpty { return .object(["meetings": .array([])]) }
        return .object([:])
    }

    private struct Node {
        let name: String
        let attributes: [String: String]
        var children: [Node] = []
        var contents = ""
        var text: String { contents.trimmingCharacters(in: .whitespacesAndNewlines) }
        var isPrivate: Bool {
            ["true", "1"].contains(attributes["is_private"] ?? attributes["isPrivate"] ?? attributes["private"] ?? "") ||
                attributes["visibility"] == "private" || attributes["type"] == "private"
        }
        var fields: [String: Value] {
            var result = attributes.mapValues(Value.string)
            for child in children where ["title", "summary", "minutes"].contains(child.name) && !child.isPrivate {
                result[child.name] = .string(child.text)
            }
            if isPrivate { result["is_private"] = .bool(true) }
            return result
        }
    }

    private final class Collector: NSObject, XMLParserDelegate {
        var root: Node?
        private var stack: [Node] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes attributeDict: [String: String]) {
            guard stack.count < 32 else { parser.abortParsing(); return }
            stack.append(Node(name: elementName, attributes: attributeDict))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if !stack.isEmpty { stack[stack.count - 1].contents += string }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if let text = String(data: CDATABlock, encoding: .utf8) { self.parser(parser, foundCharacters: text) }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?) {
            guard let node = stack.popLast() else { return }
            if stack.isEmpty { root = node } else { stack[stack.count - 1].children.append(node) }
        }
    }
}
