import Foundation
import Storage

/// Merges model-proposed style bullets into a surface's notes (`- x` lines).
public enum StyleNotesMerge {
    public static let maxBullets = 12
    public static let maxBulletChars = 120
    /// Word-set Jaccard (folded) from which a new bullet replaces an existing one.
    public static let similarity = 0.8

    public static func bullets(_ notes: String) -> [String] {
        notes.split(whereSeparator: \.isNewline).compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
                line = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                break
            }
            return line.isEmpty ? nil : line
        }
    }

    /// `- x\n` per bullet; empty for none.
    public static func render(_ b: [String]) -> String { b.map { "- \($0)\n" }.joined() }

    /// One line, trimmed, cut to `maxBulletChars`.
    public static func clean(_ bullet: String) -> String {
        let one = bullet.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return String(one.prefix(maxBulletChars)).trimmingCharacters(in: .whitespaces)
    }

    /// A new bullet replaces the existing one it nearly repeats (and counts as the newest);
    /// otherwise it is appended; the oldest are dropped beyond `max`. For notes the model owns.
    public static func merge(existing: [String], new: [String], max: Int = maxBullets) -> [String] {
        var list = existing.map(clean).filter { !$0.isEmpty }
        for raw in new {
            let bullet = clean(raw)
            guard !bullet.isEmpty else { continue }
            if let similar = list.firstIndex(where: { isSimilar($0, bullet) }) { list.remove(at: similar) }
            list.append(bullet)
        }
        return Array(list.suffix(max))
    }

    /// For a note the user owns: the raw text with the new bullets appended, byte for byte
    /// otherwise (long lines, prose and other markers are never rewritten). A near-repeat of
    /// anything already there (compared in cleaned form only) is skipped, and bullets are
    /// appended only while the note has fewer than `max` lines. Nil when nothing was appended.
    public static func append(toRaw raw: String, new: [String], max: Int = maxBullets) -> String? {
        var comparable = bullets(raw)
        var added: [String] = []
        for candidate in new {
            let bullet = clean(candidate)
            guard !bullet.isEmpty, comparable.count < max, !comparable.contains(where: { isSimilar($0, bullet) }) else { continue }
            comparable.append(bullet)
            added.append(bullet)
        }
        guard !added.isEmpty else { return nil }
        let separator = raw.isEmpty || raw.hasSuffix("\n") ? "" : "\n"
        return raw + separator + render(added)
    }

    private static func isSimilar(_ a: String, _ b: String) -> Bool {
        TextFold.jaccard(a, b) >= similarity || TextFold.key(a) == TextFold.key(b)
    }
}
