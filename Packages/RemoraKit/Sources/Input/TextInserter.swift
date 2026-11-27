import Foundation
import os

public enum InsertionTarget: Sendable, Equatable {
    /// UTF-16 range of the value the caller read.
    case range(NSRange)
    case whole
    /// Replace the current selection, or insert at the caret. The selection is never changed to do
    /// it: the AX path needs a readable selection, and the paste path pastes where the caret is.
    case caret
}

public enum InsertionOutcome: Sendable, Equatable {
    /// The text equals what it would replace: nothing was touched (field and pasteboard).
    case noChange
    /// Written through Accessibility and read back.
    case ax
    /// Pasted with ⌘V; `verified` when the value read back afterwards is the expected one.
    case paste(verified: Bool)
    /// The field's value is no longer what the rewrite was based on: nothing written.
    case fieldChanged
    /// The field is no longer focused (or another app is frontmost): nothing written.
    case notFocused
    /// The write could not be done or undone safely, or ⌘A/⌘V could not be resolved for the
    /// keyboard layout.
    case failed
}

/// Writes a rewrite back into a field: Accessibility first (verified by reading back), else a paste
/// through the general pasteboard whose previous contents are restored exactly, unless the user
/// copied something new in the meantime.
///
/// Once started, an insertion runs to the end even if the calling task is cancelled: every wait is
/// non-cancellable, so the pasteboard is never restored before the app has consumed the paste.
public struct TextInserter: Sendable {
    private static let log = Logger(subsystem: "dev.remora", category: "insert")

    private let pasteboard: any PasteboardAccess
    private let keys: any KeySynthesizing
    private let apps: any AppActivating
    private let pasteWait: Duration
    private let pollInterval: Duration
    private let axSettle: Duration
    private let ownPID: pid_t
    private let sleep: @Sendable (Duration) async -> Void

    /// `pasteWait` caps the wait for the pasted text to show up in the field (the pasteboard is
    /// restored after it, or after the full wait when the value is unreadable). `axSettle` is the
    /// grace before re-reading an AX write that reported success but read back unchanged.
    public init(pasteboard: any PasteboardAccess, keys: any KeySynthesizing, apps: any AppActivating,
                pasteWait: Duration = .milliseconds(1500), pollInterval: Duration = .milliseconds(25),
                axSettle: Duration = .milliseconds(75),
                ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
                sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.pasteboard = pasteboard; self.keys = keys; self.apps = apps
        self.pasteWait = pasteWait; self.pollInterval = pollInterval; self.axSettle = axSettle
        self.ownPID = ownPID; self.sleep = sleep
    }

    /// `expectedValue` is the field value the text was computed from (nil when it was unreadable:
    /// no AX write, no change check, an unverified paste). `preferPaste` skips the AX attempt (web
    /// views report AX writes as done without doing them). `beforePaste` runs before any paste
    /// check (hide an Edit bar holding key focus there); `afterPaste` always follows it.
    /// With `expectedSelection`, a caret insertion requires the same selection the user reviewed.
    /// Field AX calls block briefly: call this off the main actor.
    public func insert(_ text: String, target: InsertionTarget, expectedValue: String?,
                       expectedSelection: NSRange? = nil, into field: any FieldHandle,
                       preferPaste: Bool, beforePaste: @Sendable () async -> Void = {},
                       afterPaste: @Sendable () async -> Void = {}) async -> InsertionOutcome {
        var newValue: String?
        if let expectedValue {
            guard Self.same(field.value(), expectedValue) else {
                Self.log.info("insert aborted: field changed")
                return .fieldChanged
            }
            if case .caret = target {
                // The selection is read once here; without it the result is unknown (unverified paste).
                if let sel = expectedSelection ?? field.selectedRange() {
                    guard let v = Self.apply(text, .range(sel), to: expectedValue) else {
                        Self.log.error("insert failed: caret outside the field")
                        return .failed
                    }
                    newValue = v
                }
            } else {
                guard let v = Self.apply(text, target, to: expectedValue) else {
                    Self.log.error("insert failed: target range outside the field")
                    return .failed
                }
                newValue = v
            }
            // Nothing to do, and no read-back could tell a write from no write: touch nothing.
            if let newValue, Self.exact(newValue, expectedValue) {
                if let expectedSelection, field.selectedRange() != expectedSelection { return .fieldChanged }
                return .noChange
            }
        }

        // AX writes go only into the focused field, never a background one; when it is not focused
        // (an Edit bar may hold key focus) the paste path decides after `beforePaste`.
        if !preferPaste, let expectedValue, let newValue, field.isFocused() {
            if let expectedSelection, field.selectedRange() != expectedSelection { return .fieldChanged }
            switch await axWrite(text, target: target, expected: expectedValue, newValue: newValue, field) {
            case .done:
                Self.log.info("AX write verified")
                return .ax
            case .unchanged: break
            case .changedByOthers:
                Self.log.info("insert aborted: field kept changing after the AX write")
                return .fieldChanged
            case .unrecoverable:
                Self.log.error("insert failed: AX write changed the field and could not be undone")
                return .failed
            }
        }

        await beforePaste()
        let outcome = await paste(text, target: target, expected: expectedValue, newValue: newValue,
                                  expectedSelection: expectedSelection, field)
        await afterPaste()
        return outcome
    }

    // MARK: - AX

    private enum AXResult { case done, unchanged, changedByOthers, unrecoverable }

    private func axWrite(_ text: String, target: InsertionTarget, expected: String, newValue: String,
                         _ field: any FieldHandle) async -> AXResult {
        let reported: Bool
        switch target {
        case .range(let r):
            guard field.canSetSelectedText else { return .unchanged }
            reported = field.setSelectedRange(r) && field.setSelectedText(text)
        case .caret:
            guard field.canSetSelectedText else { return .unchanged }
            reported = field.setSelectedText(text)
        case .whole:
            // Select all + replace the selection: the app records an undoable edit and handles it like
            // typed text. Only when the selection reads back as the whole field: never replace the
            // selection at an unknown caret. Otherwise setValue (not undoable, may flatten rich text)
            // if settable, else the paste path.
            let whole = NSRange(location: 0, length: (field.value() ?? expected).utf16.count)
            if field.canSetSelectedText, field.setSelectedRange(whole), field.selectedRange() == whole {
                reported = field.setSelectedText(text)
            } else {
                guard field.canSetValue else { return .unchanged }
                reported = field.setValue(newValue)
            }
        }
        var after = field.value()
        if Self.landed(after, newValue: newValue, expected: expected) { return .done }
        if Self.same(after, expected) {
            guard reported else { return .unchanged }
            // Reported done but not visible yet: re-read once before pasting a second copy.
            await pause(axSettle)
            after = field.value()
            if Self.landed(after, newValue: newValue, expected: expected) { return .done }
            if Self.same(after, expected) {
                Self.log.info("AX write reported success but changed nothing; pasting")
                return .unchanged
            }
        }
        // The field now holds something else. If it is still moving, the user is typing: never
        // revert their text. Otherwise the app mangled our write: put the original back.
        guard field.value() == after else { return .changedByOthers }
        _ = field.setValue(expected)
        return Self.same(field.value(), expected) ? .unchanged : .unrecoverable
    }

    // MARK: - Paste

    private func paste(_ text: String, target: InsertionTarget, expected: String?, newValue: String?,
                       expectedSelection: NSRange?, _ field: any FieldHandle) async -> InsertionOutcome {
        if let front = apps.frontmostPID(), front != field.pid {
            // Only take focus back from Remora's own UI; never pull the user out of another app.
            guard front == ownPID, await apps.activate(pid: field.pid) else {
                Self.log.info("insert aborted: another app is frontmost")
                return .notFocused
            }
        }
        if let refusal = recheck(expected, field) { return refusal }
        guard await select(target, expected: expected, field) else {
            Self.log.error("insert failed: could not select the target text")
            return .failed
        }
        let saved = pasteboard.snapshot()
        // Last checks right before writing the pasteboard and ⌘V: the user may have typed or clicked away.
        if let refusal = recheck(expected, field) { return refusal }
        if let expectedSelection, field.selectedRange() != expectedSelection { return .fieldChanged }
        let mine = pasteboard.write(text: text)
        guard await keys.commandV() else {
            Self.log.error("insert failed: no key types v with command on this layout")
            restore(saved, ifStill: mine)
            return .failed
        }
        let verified = await waitForPaste(newValue, expected: expected, field)
        restore(saved, ifStill: mine)
        return .paste(verified: verified)
    }

    /// Pastes into whatever app is frontmost (no field known): the pasteboard is restored after
    /// `pasteWait` (the app needs time to consume the paste) unless something else was copied
    /// meanwhile. Only pastes when `expectedPID` is frontmost, and never into Remora itself.
    public func pasteIntoFrontmost(_ text: String, expectedPID: pid_t) async -> InsertionOutcome {
        guard let front = apps.frontmostPID(), front == expectedPID, front != ownPID else { return .notFocused }
        let saved = pasteboard.snapshot()
        let mine = pasteboard.write(text: text)
        guard await keys.commandV() else {
            Self.log.error("paste failed: no key types v with command on this layout")
            restore(saved, ifStill: mine)
            return .failed
        }
        await pause(pasteWait)
        restore(saved, ifStill: mine)
        return .paste(verified: false)
    }

    private func recheck(_ expected: String?, _ field: any FieldHandle) -> InsertionOutcome? {
        guard field.isFocused() else {
            Self.log.info("insert aborted: field no longer focused")
            return .notFocused
        }
        if let expected, !Self.same(field.value(), expected) {
            Self.log.info("insert aborted: field changed")
            return .fieldChanged
        }
        return nil
    }

    /// Selects the target; the selection is read back whenever the app exposes it.
    private func select(_ target: InsertionTarget, expected: String?, _ field: any FieldHandle) async -> Bool {
        switch target {
        case .caret:
            return true
        case .range(let r):
            let reported = field.setSelectedRange(r)
            // Some apps apply the selection asynchronously: read it back for a moment.
            for _ in 0..<polls(selectWait) {
                guard let selection = field.selectedRange() else { return reported }
                if selection == r { return true }
                await pause(pollInterval)
            }
            return false
        case .whole:
            let whole = (expected ?? field.value()).map { NSRange(location: 0, length: $0.utf16.count) }
            if let whole, field.setSelectedRange(whole) {
                guard let selection = field.selectedRange() else { return true }
                if selection == whole { return true }
            }
            guard await keys.commandA() else { return false }
            guard let whole else { return true }
            // ⌘A is handled asynchronously by the app: wait for the selection to cover the field.
            for _ in 0..<polls(selectWait) {
                guard let selection = field.selectedRange() else { return true }
                if selection == whole { return true }
                await pause(pollInterval)
            }
            return false
        }
    }

    /// Waits until the field shows the pasted value (the app has consumed the pasteboard), at most
    /// `pasteWait`; the full wait when the value cannot be read or never matches.
    private func waitForPaste(_ newValue: String?, expected: String?, _ field: any FieldHandle) async -> Bool {
        guard let newValue, let expected else {
            await pause(pasteWait)
            return false
        }
        for _ in 0..<polls(pasteWait) {
            if Self.landed(field.value(), newValue: newValue, expected: expected) { return true }
            await pause(pollInterval)
        }
        return Self.landed(field.value(), newValue: newValue, expected: expected)
    }

    /// A different change count means someone copied after us: never overwrite their copy.
    private func restore(_ saved: PasteboardContents, ifStill mine: Int) {
        if pasteboard.changeCount == mine {
            _ = pasteboard.restore(saved)
        } else {
            Self.log.info("pasteboard changed during paste; not restoring")
        }
    }

    /// How long a `.range` selection or ⌘A may take to show up in the read-back.
    private let selectWait: Duration = .milliseconds(300)

    private func polls(_ wait: Duration) -> Int {
        guard pollInterval > .zero else { return 1 }
        return max(1, Int((wait / pollInterval).rounded(.up)))
    }

    /// A sleep the caller's cancellation cannot cut short (an unstructured task does not inherit it).
    private func pause(_ d: Duration) async {
        let sleep = self.sleep
        await Task.detached { await sleep(d) }.value
    }

    // MARK: -

    /// The value with `text` in place of the target, or nil when the range is outside it.
    static func apply(_ text: String, _ target: InsertionTarget, to value: String) -> String? {
        let ns = value as NSString
        switch target {
        case .whole: return text
        case .caret: return nil
        case .range(let r):
            guard r.location >= 0, r.length >= 0, r.location <= ns.length, r.length <= ns.length - r.location else { return nil }
            return ns.replacingCharacters(in: r, with: text)
        }
    }

    /// Whether a write or paste has visibly happened: the field shows `newValue` exactly (line
    /// endings aside). A fuzzy match (`same`) counts only when it tells the new value apart from the
    /// one it replaces; otherwise an unchanged field would pass for a completed write.
    static func landed(_ value: String?, newValue: String, expected: String) -> Bool {
        if exact(value, newValue) { return true }
        return !same(newValue, expected) && same(value, newValue)
    }

    /// Equal once line endings are folded (CRLF/CR → LF) and nothing else.
    static func exact(_ a: String?, _ b: String) -> Bool {
        guard let a else { return false }
        return a == b || lineEndings(a) == lineEndings(b)
    }

    private static func lineEndings(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// For "did the user change it" only: equal once the usual app-side normalisations are folded
    /// away (CRLF/CR line endings, curly quotes, trailing spaces and tabs on each line).
    static func same(_ a: String?, _ b: String) -> Bool {
        guard let a else { return false }
        return a == b || fold(a) == fold(b)
    }

    private static let quotes: [Character: Character] = [
        "\u{2018}": "'", "\u{2019}": "'", "\u{201A}": "'", "\u{201B}": "'",
        "\u{201C}": "\"", "\u{201D}": "\"", "\u{201E}": "\"", "\u{201F}": "\"",
    ]

    static func fold(_ s: String) -> String {
        lineEndings(s).split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let mapped = line.map { quotes[$0] ?? $0 }
            return String(mapped.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
        }.joined(separator: "\n")
    }
}
