import Foundation
import MCP

/// Granola's MCP falls back to text with tagged sections. This is deliberately a
/// narrow parser: participants can contain literal angle brackets, and private notes
/// and attachments have their own sections that Remora never stores.
enum GranolaMeetingText {
    private static var meetingPattern: Regex<(Substring, Substring, Substring, Substring)> { /(?m)^\s*<meeting id="([A-Fa-f0-9-]+)" title="([^"\r\n]*)" date="([^"\r\n]+)"[^>]*>/ }
    private static var summaryPattern: Regex<(Substring, Substring)> { /(?ms)^\h*<summary>\s*(.*?)\s*<\/summary>/ }
    private static var privateNotesPattern: Regex<Substring> { /(?ms)^\h*<private_notes[^>]*>.*?<\/private_notes>/ }

    static func list(_ text: String) throws -> [MeetingMCPAdapter.Meeting] {
        guard text.contains("<meetings_data") else { throw MeetingImportError.invalidResponse }
        let matches = text.matches(of: meetingPattern)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy h:mm a"
        let rows = matches.compactMap { match -> MeetingMCPAdapter.Meeting? in
            let (_, id, title, date) = match.output
            guard let started = formatter.date(from: String(date)) else { return nil }
            return .init(id: String(id), startedAt: started, title: unescape(String(title)), fields: [:])
        }
        guard !rows.isEmpty || text.contains("count=\"0\"") else { throw MeetingImportError.invalidResponse }
        return rows
    }

    static func summary(_ text: String, id: String) -> String? {
        let clean = text.replacing(privateNotesPattern, with: "")
        guard !clean.contains("<private_notes"), let header = clean.matches(of: meetingPattern).first(where: { $0.output.1 == id }),
              let end = clean[header.range.upperBound...].range(of: "</meeting>") else { return nil }
        return clean[header.range.upperBound..<end.lowerBound].firstMatch(of: summaryPattern)
            .map { String($0.output.1).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static func cursor(_ text: String) -> String? {
        guard let root = text.firstMatch(of: /<meetings_data(?:\s[^>]*)?>/) else { return nil }
        let suffix = text.range(of: "</meetings_data>", options: .backwards).map { text[$0.upperBound...] } ?? ""
        return root.output.firstMatch(of: /\bnext_cursor="([A-Za-z0-9_.~+=\/-]{1,2048})"/)
            .map { String($0.output.1) }
            ?? suffix.firstMatch(of: /<next_cursor>\s*([A-Za-z0-9_.~+=\/-]{1,2048})\s*<\/next_cursor>/)
                .map { String($0.output.1) }
    }

    static func transcript(_ text: String, id: String) -> (text: String, nextOffset: Int?)? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = clean.prefixMatch(of: /<transcript(?:\s[^>]*)?>/),
              start.output.contains("meeting_id=\"\(id)\""),
              !start.output.contains("is_private=\"true\""),
              let end = clean.range(of: "</transcript>", options: .backwards) else { return nil }
        let suffix = clean[end.upperBound...]
        let explicit = start.output.firstMatch(of: /\bnext_offset="([0-9]+)"/)?.output.1
            ?? suffix.firstMatch(of: /<next_offset>\s*([0-9]+)\s*<\/next_offset>/)?.output.1
        return (clean[start.range.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines),
                explicit.flatMap { Int($0) })
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
