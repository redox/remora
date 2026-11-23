import Capture
import CoreGraphics
import Foundation
import Input
import LLM

/// A short note shown at the caret (or in the Edit bar) after a rewrite, with an optional action.
/// Carries no field content.
public struct RewriteNotice: Sendable, Equatable {
    public enum Action: Sendable, Equatable { case openSettings, manageUsage, openMicrophoneSettings, openDictationSettings }

    public var text: String
    public var action: Action?

    public init(text: String, action: Action? = nil) { self.text = text; self.action = action }

    public var actionTitle: String? {
        switch action {
        case .openSettings: "Open Settings"
        case .manageUsage: "Manage usage"
        case .openMicrophoneSettings: "Open System Settings"
        case .openDictationSettings: "Dictation settings"
        case nil: nil
        }
    }

    public static let signIn = RewriteNotice(text: "Sign in with ChatGPT to use the rewrite key", action: .openSettings)
    public static let usageLimit = RewriteNotice(text: "Usage limit reached", action: .manageUsage)
    public static let planUnavailable = RewriteNotice(text: "ChatGPT plan usage isn't available for this account")
    public static let unavailable = RewriteNotice(text: "ChatGPT is unavailable right now. Try again.")
    public static let tooLong = RewriteNotice(text: "Too long to rewrite. Select a part.")
    public static let emptyQuestion = RewriteNotice(text: "Type a question after /q")
    public static let unreadable = RewriteNotice(text: "Can't read this field")
    public static let fieldChanged = RewriteNotice(text: "Field changed, nothing inserted")
    public static let lostFocus = RewriteNotice(text: "Field lost focus, nothing inserted")
    public static let couldNotInsert = RewriteNotice(text: "Couldn't insert here")
    public static let generic = RewriteNotice(text: "Something went wrong")
    public static let richField = RewriteNotice(
        text: "This field has attachments or formatting Remora can't rewrite whole — select the text to rewrite")

    public static func onDeviceUnavailable(_ reason: String) -> RewriteNotice {
        RewriteNotice(text: "On-device model unavailable — \(reason)")
    }

    /// An on-device-only rewrite (excluded, private or unverifiable context) could not run locally:
    /// nothing was sent anywhere.
    public static func notCapturedOnDeviceUnavailable(_ reason: String) -> RewriteNotice {
        RewriteNotice(text: "Remora doesn't capture here, so it only rewrites with the on-device model — unavailable: \(reason)")
    }
}

/// What a rewrite may use besides the field's own text.
public struct RewriteAccess: Sendable, Equatable {
    /// The window title and live window text may go into the prompt.
    public var windowContextAllowed: Bool
    /// Stored memory may be retrieved for the prompt.
    public var memoryAllowed: Bool
    /// The result may be stored in `inline_outputs`.
    public var logAllowed: Bool
    /// The field's text may go to a cloud model. Prompt-only Insert needs no field text.
    public var cloudAllowed: Bool

    public init(windowContextAllowed: Bool, memoryAllowed: Bool, logAllowed: Bool, cloudAllowed: Bool) {
        self.windowContextAllowed = windowContextAllowed; self.memoryAllowed = memoryAllowed; self.logAllowed = logAllowed
        self.cloudAllowed = cloudAllowed
    }

    /// Paused capture: field text only, nothing stored; the cloud may be used.
    public static let fieldOnlyCloud = RewriteAccess(windowContextAllowed: false, memoryAllowed: false, logAllowed: false,
                                                     cloudAllowed: true)
    /// Excluded, private or unverifiable context: field text only, nothing stored, on-device model only.
    public static let fieldOnlyOnDevice = RewriteAccess(windowContextAllowed: false, memoryAllowed: false, logAllowed: false,
                                                        cloudAllowed: false)
}

public enum RewriteGate: Sendable, Equatable {
    /// A password manager (app or web vault), or a browser page that cannot be verified: refused
    /// like a secure field (beep, nothing sent).
    case refuse
    case proceed(RewriteAccess)
}

/// Whether a rewrite or Edit mode may start: the privacy gate first, then the sign-in check.
public enum RewritePreflight: Sendable, Equatable {
    /// Beep, nothing sent, no notice.
    case refuse
    case notice(RewriteNotice)
    case proceed(RewriteAccess)
}

/// What a rewrite works on, decided from the focused field's snapshot.
public struct RewritePlan: Sendable, Equatable {
    public var mode: RewriteMode
    /// The text the engine sees as the field's value.
    public var fieldValue: String
    /// What the field must still hold when the result is written; nil when only the selected
    /// text was readable (no change check is possible then).
    public var expectedValue: String?
    /// For a selected-text-only read: where that text sits in the field.
    var selectionInField: NSRange?
    /// Keep the insertion at the caret the draft was generated for.
    public var expectedSelection: NSRange?

    /// Paste directly at the caret in a rich field so a failed AX write cannot flatten an attachment.
    public var prefersPaste: Bool {
        switch mode {
        case .draft, .draftAtCaret: fieldValue.contains(RewriteFlow.objectReplacement)
        case .selection, .full, .question: false
        }
    }

    /// Where the result goes.
    public func target(for output: RewriteOutput) -> InsertionTarget {
        if let selectionInField { return .range(selectionInField) }
        switch mode {
        case .draft, .draftAtCaret: return .caret
        case .selection, .full, .question: break
        }
        return output.range == NSRange(location: 0, length: fieldValue.utf16.count) ? .whole : .range(output.range)
    }
}

/// One Edit-mode round, prepared from the field's current value. `session` is the resynced
/// session; the caller commits the session returned by `applying` only once the write landed.
public struct EditRound: Sendable {
    public var session: EditSession
    /// The text the instruction applies to and where it sits in the field (UTF-16).
    public var text: String
    public var range: NSRange

    /// The session after writing `result`, and the field's new whole value.
    public func applying(_ result: String, to currentValue: String) -> (session: EditSession, value: String) {
        var next = session
        let value = next.didWrite(result: result, into: currentValue)
        return (next, value)
    }
}

/// The rewrite key's decisions, kept pure so they are unit-tested (the app only wires them up).
///
/// Privacy rule (`gate`): where capture is allowed the rewrite key and Edit mode may use the cloud
/// with the window title, window text and memory, and are logged. While capture is paused they
/// use the cloud with the field text only and store nothing. In contexts Remora does not capture
/// (the ignore list, built-in skips, private windows, unreadable or other-process non-browser
/// contexts) they run on the on-device model only, with the field text only, and store nothing; if
/// that model is unavailable they fail closed and never call the cloud. Password managers, secure
/// fields, vault pages and browser pages that cannot be verified are refused: beep, nothing sent.
public enum RewriteFlow {
    // MARK: Plan

    /// nil when there is nothing safe to work on ("Can't read this field"). Throws `.richContent`
    /// when the text the result would replace holds an attachment (U+FFFC): writing plain text over
    /// it would drop the attachment or its formatting.
    public static func plan(value: String?, selection: NSRange?, selectedText: String?,
                            placeholder: String?) throws(RewriteError) -> RewritePlan? {
        if let value {
            let mode = RewriteMode.decide(value: value, selection: selection, placeholder: placeholder)
            let replaced: String
            switch mode {
            case .selection(let r):
                let clamped = NSIntersectionRange(r, NSRange(location: 0, length: value.utf16.count))
                replaced = clamped.length > 0 ? (value as NSString).substring(with: clamped) : ""
            case .draft, .draftAtCaret:
                // An unknown caret is safe only in an empty field. In an existing field a blind
                // paste could land at a different position or overwrite a hidden selection.
                guard let selection else {
                    return value.isEmpty ? RewritePlan(mode: mode, fieldValue: value, expectedValue: value) : nil
                }
                guard selection.length == 0, (0...value.utf16.count).contains(selection.location) else {
                    throw .selectionOutOfBounds
                }
                return RewritePlan(mode: mode, fieldValue: value, expectedValue: value, expectedSelection: selection)
            case .full, .question: replaced = value
            }
            if replaced.contains(objectReplacement) { throw .richContent }
            return RewritePlan(mode: mode, fieldValue: value, expectedValue: value)
        }
        // Some apps expose only the selected text: rewrite exactly that, in place.
        guard let selectedText, !selectedText.isEmpty, let selection, selection.length > 0 else { return nil }
        if selectedText.contains(objectReplacement) { throw .richContent }
        return RewritePlan(mode: .full, fieldValue: selectedText, expectedValue: nil, selectionInField: selection)
    }

    /// Edit mode writes the whole value back: a field holding an attachment is refused (`.richContent`).
    public static func checkEditable(_ value: String) throws(RewriteError) {
        if value.contains(objectReplacement) { throw .richContent }
    }

    /// U+FFFC OBJECT REPLACEMENT CHARACTER: how AX values show an attachment (image, file, mention chip).
    public static let objectReplacement: Character = "\u{FFFC}"

    // MARK: Privacy gate

    /// Decides from the frontmost window's context what a rewrite may use. Password managers and
    /// their web vaults are refused outright, and so is a browser field whose context is unreadable
    /// or belongs to another process (its page could be a vault). An excluded, private, unknown or
    /// unreadable context, or a non-browser context of another process, gets the field text only on
    /// the on-device model (`.fieldOnlyOnDevice`). Paused capture of a capturable context gets the
    /// field text only in the cloud (`.fieldOnlyCloud`). Neither stores anything.
    public static func gate(context: WindowContext?, contextPID: pid_t?, fieldPID: pid_t, fieldBundleID: String?,
                            policy: CapturePolicy, paused: Bool) -> RewriteGate {
        if let id = fieldBundleID, BuiltInSkipList.bundleIDs.contains(id) { return .refuse }
        if let context {
            if let id = context.bundleID, BuiltInSkipList.bundleIDs.contains(id) { return .refuse }
            if BuiltInSkipList.isPasswordVault(host: context.domain) { return .refuse }
        }
        if BrowserCatalog.isBrowser(fieldBundleID), context == nil || contextPID != fieldPID { return .refuse }
        guard let context, contextPID == fieldPID, policy.shouldCapture(context) else { return .proceed(.fieldOnlyOnDevice) }
        if paused { return .proceed(.fieldOnlyCloud) }
        return .proceed(RewriteAccess(windowContextAllowed: true, memoryAllowed: true, logAllowed: true, cloudAllowed: true))
    }

    /// The gate decides first, so a refused field never shows "Sign in"; pass the sign-in notice
    /// only for a field the gate let through. An on-device-only rewrite needs no ChatGPT account.
    public static func preflight(gate: RewriteGate, signIn: RewriteNotice?) -> RewritePreflight {
        guard case .proceed(let access) = gate else { return .refuse }
        if access.cloudAllowed, let signIn { return .notice(signIn) }
        return .proceed(access)
    }

    /// The style surface: the page's domain in a browser (pass a context only when it may be
    /// used), otherwise the bundle id, otherwise the app name.
    public static func surface(app: String, bundleID: String?, context: WindowContext?) -> String {
        if BrowserCatalog.isBrowser(bundleID), let domain = context?.domain { return domain }
        return bundleID ?? app
    }

    /// Whether the 45 s outcome check may store what the field holds now: capture is not paused,
    /// the frontmost context is readable, belongs to the field's process, is capturable under the
    /// current rules and is not a vault, and the field still has focus. Fails closed.
    public static func mayRecordOutcome(paused: Bool, context: WindowContext?, contextPID: pid_t?, fieldPID: pid_t,
                                        policy: CapturePolicy, fieldFocused: Bool) -> Bool {
        guard !paused, fieldFocused, let context, contextPID == fieldPID else { return false }
        if BuiltInSkipList.isPasswordVault(host: context.domain) { return false }
        return policy.shouldCapture(context)
    }

    /// The request for one Edit-mode round. While capture is paused the round uses the field only
    /// and stores nothing. After the first write the live window text read when the bar opened is
    /// stale, so it is dropped (the title stays).
    public static func roundRequest(_ base: RewriteRequest, fieldValue: String, paused: Bool, wroteBefore: Bool) -> RewriteRequest {
        var r = base
        r.mode = .full
        r.fieldValue = fieldValue
        if wroteBefore { r.liveWindowText = nil }
        if paused {
            r.windowTitle = nil
            r.liveWindowText = nil
            r.memoryAllowed = false
            r.logAllowed = false
        }
        return r
    }

    /// No window title or window text goes into the prompt (shown as "Field only" in the Edit bar).
    public static func isFieldOnly(_ r: RewriteRequest) -> Bool { r.windowTitle == nil && r.liveWindowText == nil }

    /// The Edit bar's footer: the backend that answered the last round, or nil before a round when
    /// the route is not settled yet (an on-device tier may fall back to ChatGPT); "Field only" when
    /// window context was withheld. On-device-only rounds (a context Remora doesn't capture) say so.
    public static func editBarFooter(backend: LLMBackend?, fieldOnly: Bool, onDeviceOnly: Bool = false) -> String {
        if onDeviceOnly { return "On-device (not captured)" }
        let name = switch backend {
        case .siwc: "Using ChatGPT plan"
        case .onDevice: "On-device"
        case .apiKey: "Using API key"
        case nil: "On-device or ChatGPT"
        }
        return fieldOnly ? name + " · Field only" : name
    }

    /// Settings' line for a fallback chord that is not registered; nil when it is.
    public static func chordError(_ chord: KeyChord, name: String, registered: Bool) -> String? {
        if registered { return nil }
        guard chord.isUsableHotKey else { return "\(name) can't be used as a shortcut. Include ⌘, ⌃ or ⌥." }
        return "\(name) is used by another app. Pick another shortcut."
    }

    // MARK: Messages

    /// The note to show before a rewrite starts, when the job's tier needs a ChatGPT sign-in
    /// that is missing. `.unavailable` (unreadable Keychain) is left to the call itself.
    public static func signInNotice(state: SignInState, tier: Tier) -> RewriteNotice? {
        guard tier != .onDevice else { return nil }
        switch state {
        case .signedOut, .needsSignIn: return .signIn
        case .signedIn(_, let planUsage): return planUsage ? nil : .planUnavailable
        case .unavailable: return nil
        }
    }

    /// nil for a cancellation (the user did it). `onDeviceOnly`: the request was not allowed to use
    /// the cloud (an excluded context).
    public static func notice(for error: any Error, onDeviceOnly: Bool = false) -> RewriteNotice? {
        if error is CancellationError { return nil }
        if let e = error as? LLMError {
            if onDeviceOnly, case .onDeviceUnavailable(let reason) = e { return .notCapturedOnDeviceUnavailable(reason) }
            switch e {
            case .cancelled: return nil
            case .usageLimit: return .usageLimit
            case .needsSignIn, .notSignedIn: return .signIn
            case .planUsageDisabled, .notEligible: return .planUnavailable
            case .onDeviceUnavailable(let reason): return .onDeviceUnavailable(reason)
            default: return e.isRetryable ? .unavailable : .generic
            }
        }
        if let e = error as? RewriteError {
            switch e {
            case .tooLong: return .tooLong
            case .emptyQuestion: return .emptyQuestion
            case .unreadableField: return .unreadable
            case .selectionOutOfBounds: return .fieldChanged
            case .emptyResult: return .generic
            case .richContent: return .richField
            }
        }
        return .generic
    }

    /// nil when the write succeeded or there was nothing to write (`.noChange`).
    public static func notice(for outcome: InsertionOutcome) -> RewriteNotice? {
        switch outcome {
        case .ax, .paste, .noChange: nil
        case .fieldChanged: .fieldChanged
        case .notFocused: .lostFocus
        case .failed: .couldNotInsert
        }
    }

    /// The text was written into the field (logged and checked later); `.noChange` wrote nothing.
    public static func didInsert(_ outcome: InsertionOutcome) -> Bool {
        switch outcome {
        case .ax, .paste: true
        case .noChange, .fieldChanged, .notFocused, .failed: false
        }
    }

    // MARK: Edit mode

    /// Resyncs the session with the field and returns what the instruction applies to. Throws
    /// `.selectionOutOfBounds` when the user's new selection lies outside the field.
    /// Throws `.richContent` when the field now holds an attachment (pasted since the last round).
    public static func editRound(_ session: EditSession, currentValue: String, selection: NSRange?) throws(RewriteError) -> EditRound {
        try checkEditable(currentValue)
        var s = session
        try s.resync(currentValue: currentValue, selection: selection)
        let text = s.targetText(in: currentValue)
        let range = NSRange(location: min(s.target.location, currentValue.utf16.count), length: text.utf16.count)
        return EditRound(session: s, text: text, range: range)
    }

    /// The value to write back for ⌘Z, with the session to commit after the write. nil when there
    /// is nothing to undo, or the user changed the field since our last write (undoing would
    /// clobber their text).
    public static func undoRound(_ session: EditSession, currentValue: String, selection: NSRange?) -> (session: EditSession, value: String)? {
        var s = session
        guard (try? s.resync(currentValue: currentValue, selection: selection)) != nil, s.canUndo,
              let value = s.undo() else { return nil }
        return (s, value)
    }

    // MARK: Layout (Cocoa coordinates: bottom-left origin)

    /// A document-sized AX element is a poor anchor for a selection. Prefer the text bounds,
    /// then a nearby pointer for mouse selections or a caret when the pointer is elsewhere.
    public static func editBarAnchor(field: CGRect?, selection: CGRect?, caret: CGRect?,
                                     preferNearbyPointer: Bool, pointer: CGPoint) -> CGRect {
        let field = field.flatMap { usableAnchor($0) ? $0 : nil }
        if let selection, usableAnchor(selection),
           field.map({ $0.intersects(selection) && !selection.contains($0) }) ?? true {
            return selection
        }
        if let field {
            if !preferNearbyPointer { return field }
            if !field.contains(pointer) {
                if let caret, usableAnchor(caret), field.intersects(caret) { return caret }
                return field
            }
        }
        // Leave room for the line under the pointer when a document does not give text bounds.
        return CGRect(x: pointer.x - 180, y: pointer.y - 12, width: 360, height: 24)
    }

    /// The Edit bar: 8 pt from its anchor, preferring above when it fits, kept on screen.
    public static func editBarFrame(field: CGRect, height: CGFloat, visible: CGRect) -> CGRect {
        let height = min(height, visible.height)
        let width = min(max(field.width, 360), 560, visible.width)
        let gap: CGFloat = 8
        let above = visible.maxY - field.maxY - gap
        let below = field.minY - visible.minY - gap
        let useAbove = above >= height || (below < height && above > below)
        let y = useAbove ? field.maxY + gap : field.minY - gap - height
        let x = clamp(field.minX, visible.minX, visible.maxX - width)
        return CGRect(x: x, y: clamp(y, visible.minY, visible.maxY - height), width: width, height: height)
    }

    /// Keep the indicator above and to the right of the caret. At the top of the screen, move it
    /// below the line so clamping at either horizontal edge cannot cover the caret.
    public static func indicatorFrame(caret: CGRect, size: CGSize, visible: CGRect) -> CGRect {
        let gap: CGFloat = 3
        let x = clamp(caret.maxX + gap, visible.minX, visible.maxX - size.width)
        var y = caret.maxY + gap
        if y + size.height > visible.maxY { y = caret.minY - gap - size.height }
        y = clamp(y, visible.minY, visible.maxY - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { max(lo, min(v, max(lo, hi))) }

    private static func usableAnchor(_ rect: CGRect) -> Bool {
        !rect.isEmpty && !rect.isInfinite && rect.midX.isFinite && rect.midY.isFinite
    }
}
