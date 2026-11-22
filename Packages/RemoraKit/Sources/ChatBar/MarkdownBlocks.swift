import Foundation

public enum MarkdownBlock: Sendable, Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(depth: Int, text: String)
    case numbered(number: Int, text: String)
    case quote(String)
    case code(language: String?, text: String, closed: Bool)
    case rule
}

public enum MarkdownBlocks {
    private static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    /// Inputs longer than this are cut (parsed prefix + a marker paragraph).
    /// Streaming callers reparse the whole accumulated text on every update.
    static let maxInputCharacters = 200_000
    static let maxLanguageCharacters = 32
    static let maxBulletDepth = 6
    static let truncationMarker = "[… truncated]"

    public static func parse(_ md: String) -> [MarkdownBlock] {
        var md = md
        var truncated = false
        if md.count > maxInputCharacters {
            md = String(md.prefix(maxInputCharacters))
            truncated = true
        }
        // "\r\n" is a single Character in Swift, so normalise before splitting.
        md = md.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var blocks: [MarkdownBlock] = []
        var para: [String] = []
        var quote: [String] = []
        var code: (lang: String?, lines: [String])?

        func flushPara() { if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))); para = [] } }
        func flushQuote() { if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] } }

        for raw in md.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let c = code {
                if trimmed == "```" {
                    blocks.append(.code(language: c.lang, text: c.lines.joined(separator: "\n"), closed: true))
                    code = nil
                } else {
                    code?.lines.append(line)
                }
                continue
            }
            if trimmed.hasPrefix("```"), !trimmed.dropFirst(3).contains("`") {
                flushPara(); flushQuote()
                let lang = String(trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).prefix(maxLanguageCharacters))
                code = (lang.isEmpty ? nil : lang, [])
                continue
            }
            if trimmed.isEmpty { flushPara(); flushQuote(); continue }
            if trimmed.count >= 3, trimmed.allSatisfy({ $0 == "-" }) {
                flushPara(); flushQuote(); blocks.append(.rule); continue
            }
            if let h = heading(trimmed) {
                flushPara(); flushQuote(); blocks.append(h); continue
            }
            if trimmed.hasPrefix(">") {
                flushPara()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            if let b = listItem(line) {
                flushPara(); flushQuote(); blocks.append(b); continue
            }
            flushQuote()
            para.append(trimmed)
        }
        flushPara(); flushQuote()
        if let c = code {
            blocks.append(.code(language: c.lang, text: c.lines.joined(separator: "\n"), closed: false))
        }
        if truncated { blocks.append(.paragraph(truncationMarker)) }
        return blocks
    }

    private static func heading(_ t: String) -> MarkdownBlock? {
        let hashes = t.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = t.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return .heading(level: hashes, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> MarkdownBlock? {
        let indent = line.prefix { $0 == " " }.count
        let body = line.dropFirst(indent)
        if let f = body.first, "-*+".contains(f), body.dropFirst().first == " " {
            return .bullet(depth: min(indent / 2, maxBulletDepth), text: body.dropFirst(2).trimmingCharacters(in: .whitespaces))
        }
        let digits = body.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, digits.count <= 9, let n = Int(digits) {
            let after = body.dropFirst(digits.count)
            if let d = after.first, d == "." || d == ")", after.dropFirst().first == " " {
                return .numbered(number: n, text: after.dropFirst(2).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    /// Inline Markdown with every non-web link neutralised (text kept, link removed).
    public static func inline(_ text: String) -> AttributedString {
        var out = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        var unsafe: [Range<AttributedString.Index>] = []
        for run in out.runs {
            guard let url = run.link else { continue }
            if !allowedSchemes.contains(url.scheme?.lowercased() ?? "") { unsafe.append(run.range) }
        }
        for r in unsafe { out[r].link = nil }
        // Never let inline markdown load a remote image.
        var images: [Range<AttributedString.Index>] = []
        for run in out.runs where run.imageURL != nil { images.append(run.range) }
        for r in images { out[r].imageURL = nil }
        return out
    }
}
