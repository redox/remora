import AppKit

/// Each prose section is one native selection range. Fenced code and dividers are separate views.
public enum MarkdownSection {
    case prose(NSAttributedString)
    case code(language: String?, text: String)
    case rule
}

@MainActor
public struct ChatMarkdown {
    private let fontSize: CGFloat

    public init(fontSize: CGFloat) {
        self.fontSize = fontSize
    }

    public func sections(_ text: String) -> [MarkdownSection] {
        var sections: [MarkdownSection] = []
        var prose = NSMutableAttributedString()
        func flush() {
            if prose.length > 0 { sections.append(.prose(prose)) }
            prose = NSMutableAttributedString()
        }
        for block in MarkdownBlocks.parse(text) {
            switch block {
            case .code(let language, let code, _):
                flush()
                sections.append(.code(language: language, text: code))
            case .rule:
                flush()
                sections.append(.rule)
            case .heading(let level, let text):
                let size = fontSize + CGFloat(max(0, 4 - level)) * 1.5
                append(text, to: prose, font: .systemFont(ofSize: size, weight: .semibold))
            case .paragraph(let text):
                append(text, to: prose)
            case .bullet(let depth, let text):
                append(text, to: prose, prefix: depth == 0 ? "•  " : "◦  ", indent: CGFloat(depth) * 14)
            case .numbered(let number, let text):
                append(text, to: prose, prefix: "\(number).  ")
            case .quote(let text):
                append(text, to: prose, prefix: "│  ", color: .secondaryLabelColor)
            }
        }
        flush()
        return sections
    }

    private func append(_ text: String, to prose: NSMutableAttributedString, font: NSFont? = nil,
                        prefix: String = "", indent: CGFloat = 0, color: NSColor = .labelColor) {
        let font = font ?? .systemFont(ofSize: fontSize)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacing = 6
        style.firstLineHeadIndent = indent
        style.headIndent = indent + (prefix as NSString).size(withAttributes: [.font: font]).width
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        if prose.length > 0 {
            // The paragraph separator belongs to the previous block, including its indentation.
            let previousStyle = prose.attribute(.paragraphStyle, at: prose.length - 1, effectiveRange: nil)
            prose.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: previousStyle ?? style]))
        }
        if !prefix.isEmpty { prose.append(NSAttributedString(string: prefix, attributes: base)) }
        let inline = MarkdownBlocks.inline(text)
        for run in inline.runs {
            var attributes = base
            let intent = run.inlinePresentationIntent ?? []
            var face = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular) : font
            if intent.contains(.stronglyEmphasized) { face = NSFontManager.shared.convert(face, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { face = NSFontManager.shared.convert(face, toHaveTrait: .italicFontMask) }
            attributes[.font] = face
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let url = run.link {
                attributes[.link] = url
                attributes[.toolTip] = url.absoluteString
            }
            prose.append(NSAttributedString(string: String(inline.characters[run.range]), attributes: attributes))
        }
    }
}
