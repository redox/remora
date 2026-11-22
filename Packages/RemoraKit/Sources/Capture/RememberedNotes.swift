import Foundation
import Redaction
import Storage

public struct RememberedNotes: Sendable {
    public enum Refusal: Error, Equatable {
        case sourceUnavailable, empty, tooLong
    }

    public static let maximumTextBytes = 16_000
    public static let maximumAnnotationBytes = 2_000
    private let db: AppDatabase

    public init(_ db: AppDatabase) { self.db = db }

    public func allowsSelection(from source: WindowContext, now: Date = Date()) throws -> Bool {
        guard try !SettingsStore(db).isPaused(now: now) else { return false }
        return Self.allows(source, rules: try ExclusionStore(db).entries())
    }

    private static func allows(_ source: WindowContext, rules: [ExclusionStore.Entry]) -> Bool {
        guard source.bundleID != nil, CapturePolicy(userRules: []).shouldCapture(source) else { return false }
        var source = source
        if BrowserCatalog.isBrowser(source.bundleID) {
            guard let url = source.url else { return false }
            if url.isFileURL {
                source.filePath = url.path(percentEncoded: false)
            } else if source.domain == nil || !["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                return false
            }
        }
        return rules.allSatisfy { entry in
            guard let rule = ExclusionRule(pattern: entry.pattern) else { return false }
            return !rule.matches(source) || (rule.supportsManualSaves && entry.manualSaves)
        }
    }

    /// A source is supplied for AX selections. An explicitly typed or pasted note has no source.
    public func save(_ text: String, annotation: String, from source: WindowContext? = nil,
                     generation: Int, now: Date = Date()) throws -> SavedNote {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let annotation = annotation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Refusal.empty }
        guard text.utf8.count <= Self.maximumTextBytes,
              annotation.utf8.count <= Self.maximumAnnotationBytes else { throw Refusal.tooLong }
        let redactor = Redactor()
        let note = SavedNote(text: redactor.redact(text), annotation: redactor.redact(annotation), createdAt: now)
        return try DataGeneration.write(db, expected: generation) { d in
            if let source {
                let paused = try SettingsStore(db).pausedUntil(in: d).map { $0 > now } ?? false
                guard !paused, Self.allows(source, rules: try ExclusionStore.entries(in: d))
                else { throw Refusal.sourceUnavailable }
            }
            try SavedNoteStore.insert(note, in: d)
            return note
        }
    }
}
