import Foundation
import Storage

/// Keeps the user's edits to the identity profile across model rewrites. Lines are compared
/// through `TextFold` (case, accents, quotes and whitespace do not matter).
public enum IdentityMerge {
    /// The heading `enforce` puts re-added user lines under (created once).
    public static let notesHeading = "### Notes from you"

    /// Trimmed, non-empty lines.
    public static func lines(_ body: String) -> [String] {
        body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Lines of `user` that `previousLLM` did not have.
    public static func userAdded(previousLLM: String, user: String) -> [String] {
        difference(lines(user), minus: lines(previousLLM))
    }

    /// Lines of `previousLLM` that `user` no longer has.
    public static func userRemoved(previousLLM: String, user: String) -> [String] {
        difference(lines(previousLLM), minus: lines(user))
    }

    private static func difference(_ a: [String], minus b: [String]) -> [String] {
        let drop = Set(b.map(TextFold.fold))
        var seen = Set<String>(), out: [String] = []
        for line in a {
            let key = TextFold.fold(line)
            guard !drop.contains(key), key != TextFold.fold(notesHeading), seen.insert(key).inserted else { continue }
            out.append(line)
        }
        return out
    }

    /// The lines to keep and the lines never to bring back, replayed over the whole history
    /// (oldest first) pairwise: each user revision against the revision before it (the empty text
    /// before the first). The later user revision wins (F-33): a line the user added and later
    /// deleted is only in `mustNotReintroduce`; a line the user deleted and later re-added is only
    /// in `mustKeep`.
    public static func constraints(_ history: [IdentityRevision]) -> (mustKeep: [String], mustNotReintroduce: [String]) {
        var keep: [(key: String, text: String)] = [], never: [(key: String, text: String)] = []
        for (i, revision) in history.enumerated() where revision.source == .user {
            let previous = i > 0 ? history[i - 1].body : ""
            for line in userRemoved(previousLLM: previous, user: revision.body) {
                let key = TextFold.fold(line)
                keep.removeAll { $0.key == key }
                never.removeAll { $0.key == key }
                never.append((key, line))
            }
            for line in userAdded(previousLLM: previous, user: revision.body) {
                let key = TextFold.fold(line)
                never.removeAll { $0.key == key }
                keep.removeAll { $0.key == key }
                keep.append((key, line))
            }
        }
        return (keep.map(\.text), never.map(\.text))
    }

    /// Drops output lines the user removed and appends every `mustKeep` line the output lacks
    /// under one final `### Notes from you` heading (created once: an output that already has
    /// the heading gets the missing lines inside that section). A line in both lists is kept.
    public static func enforce(output: String, mustKeep: [String], mustNotReintroduce: [String]) -> String {
        let keepKeys = Set(mustKeep.map(TextFold.fold))
        let never = Set(mustNotReintroduce.map(TextFold.fold)).subtracting(keepKeys)
        var rows = output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
            .filter { line in
                let key = TextFold.fold(line)
                return key.isEmpty || !never.contains(key)
            }
        while let last = rows.last, last.trimmingCharacters(in: .whitespaces).isEmpty { rows.removeLast() }
        let present = Set(rows.map(TextFold.fold))
        var seen = Set<String>(), missing: [String] = []
        for line in mustKeep.map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
            let key = TextFold.fold(line)
            if !present.contains(key), seen.insert(key).inserted { missing.append(line) }
        }
        guard !missing.isEmpty else { return rows.joined(separator: "\n") }
        let headingKey = TextFold.fold(notesHeading)
        if let at = rows.firstIndex(where: { TextFold.fold($0) == headingKey }) {
            var end = at + 1
            while end < rows.count, !rows[end].hasPrefix("#") { end += 1 }
            while end > at + 1, rows[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
            rows.insert(contentsOf: missing, at: end)
            return rows.joined(separator: "\n")
        }
        return (rows + (rows.isEmpty ? [] : [""]) + [notesHeading] + missing).joined(separator: "\n")
    }
}
