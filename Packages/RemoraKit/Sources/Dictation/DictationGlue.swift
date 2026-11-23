import Capture
import Foundation
import Input
import Rewrite

extension DictationNotice {
    public var writingNotice: RewriteNotice {
        let writingAction: RewriteNotice.Action? = switch action {
        case .openMicrophoneSettings: .openMicrophoneSettings
        case .openDictationSettings: .openDictationSettings
        case nil: nil
        }
        return RewriteNotice(text: text, action: writingAction)
    }
}

extension CleanupRoute {
    /// The cleanup route for a dictation. Only password managers (the field's or the window's app on
    /// the built-in skip list) and password-vault pages refuse; secure fields are refused before
    /// this (`DictationTarget`). Everything else follows Plan 2's rewrite gate, except that a page
    /// the gate cannot verify (a browser field whose window context is missing or belongs to another
    /// process) is cleaned on-device instead of discarding the user's words. No known target
    /// (`fieldPID == nil`) is on-device only.
    public static func forDictation(context: WindowContext?, contextPID: pid_t?, fieldPID: pid_t?,
                                    fieldBundleID: String?, policy: CapturePolicy, paused: Bool) -> CleanupRoute {
        for id in [fieldBundleID, context?.bundleID] {
            if let id, BuiltInSkipList.bundleIDs.contains(id) { return .refuse }
        }
        if BuiltInSkipList.isPasswordVault(host: context?.domain) { return .refuse }
        guard let fieldPID else { return .onDeviceOnly }
        switch RewriteFlow.gate(context: context, contextPID: contextPID, fieldPID: fieldPID,
                                fieldBundleID: fieldBundleID, policy: policy, paused: paused) {
        case .refuse: return .onDeviceOnly
        case .proceed(let access): return access.cloudAllowed ? .cloud : .onDeviceOnly
        }
    }
}

extension DictationTarget {
    /// Where the text goes, decided from the focused-field read done at insertion time
    /// (`fieldRefusal == nil`: a usable field is focused). Secure Input on at that moment (a password
    /// field or Secure Keyboard Entry took focus while the user spoke) refuses everything: nothing
    /// is ever written or pasted into a secure context.
    public static func atInsertion(fieldRefusal: FieldRefusal?, secureInputOn: Bool) -> DictationTarget {
        if secureInputOn { return .refuseSecure }
        switch fieldRefusal {
        case nil: return decide(fieldPresent: true, isSecure: false, frontmostIsSelf: false)
        case .secureField?, .passwordManager?: return decide(fieldPresent: false, isSecure: true, frontmostIsSelf: false)
        case .ownApp?: return decide(fieldPresent: false, isSecure: false, frontmostIsSelf: true)
        case .noFocusedElement?: return decide(fieldPresent: false, isSecure: false, frontmostIsSelf: false)
        // A busy app may handle ⌘V only after the clipboard is restored and paste the user's previous
        // clipboard: never paste blind into it; the text goes to the clipboard instead.
        case .notResponding?: return .nowhere
        }
    }
}

extension DictationSpacing {
    /// The character just before the selection (UTF-16 `selection`, as Accessibility reports it), or
    /// nil when it is unknown: no value, no selection, a range outside the value, or a location
    /// inside a composed character.
    public static func preceding(value: String?, selection: NSRange?) -> Character? {
        guard let value, let selection, selection.location != NSNotFound, selection.location > 0 else { return nil }
        let utf16 = value.utf16
        guard selection.location <= utf16.count,
              let end = utf16.index(utf16.startIndex, offsetBy: selection.location, limitedBy: utf16.endIndex),
              let endIndex = end.samePosition(in: value) else { return nil }
        return value[..<endIndex].last
    }
}

/// Routes the shared rewrite key while the popover owns a draft.
public enum EditVoiceRoute {
    public enum Submission: Sendable {
        case edit, compose, insertText
    }

    public enum Mode: Hashable, Sendable {
        case insert, edit

        public var other: Mode { self == .insert ? .edit : .insert }

        public static func preferred(replacesSelection: Bool) -> Mode {
            replacesSelection ? .edit : .insert
        }

        public func submission(hasFallback: Bool) -> Submission {
            if self == .edit { return .edit }
            return hasFallback ? .insertText : .compose
        }

        public func actionTitle(replacesSelection: Bool) -> String {
            switch self {
            case .edit: replacesSelection ? "Rewrite selection" : "Apply as edit"
            case .insert: replacesSelection ? "Replace selection" : "Insert at caret"
            }
        }
    }

    public struct State: Sendable {
        public var dictationActive: Bool
        public var voiceHold: Bool
        public var canDictateInstruction: Bool
        public var rewriteWorking: Bool
        public var barOpen: Bool
        public var holdOpenedBar: Bool

        public init(dictationActive: Bool, voiceHold: Bool, canDictateInstruction: Bool, rewriteWorking: Bool,
                    barOpen: Bool, holdOpenedBar: Bool) {
            self.dictationActive = dictationActive
            self.voiceHold = voiceHold
            self.canDictateInstruction = canDictateInstruction
            self.rewriteWorking = rewriteWorking
            self.barOpen = barOpen
            self.holdOpenedBar = holdOpenedBar
        }
    }

    public enum Action: Sendable, Equatable {
        case ignore, rewrite, openPopover, switchMode, showHoldHint, hideHoldHint
        case beginInstruction(openBar: Bool)
        case finishInstruction
        case cancelInstruction(closeBar: Bool)
    }

    public static func decide(_ output: TapDetector.Output, _ state: State) -> Action {
        if state.voiceHold {
            switch output {
            case .holdReleased: return .finishInstruction
            case .holdCancelled: return .cancelInstruction(closeBar: state.holdOpenedBar)
            case .singleTap, .doubleTap, .holdArmed: return .ignore
            }
        }
        if state.barOpen, output == .singleTap { return .switchMode }
        if state.dictationActive { return .ignore }
        switch output {
        case .singleTap, .holdReleased: return .openPopover
        case .doubleTap: return state.barOpen ? .ignore : .rewrite
        case .holdArmed:
            guard !state.rewriteWorking else { return .ignore }
            return state.canDictateInstruction ? .beginInstruction(openBar: !state.barOpen) : .showHoldHint
        case .holdCancelled: return .hideHoldHint
        }
    }

    /// A hold that opened the bar cannot take focus while Option is still down. A key typed in
    /// that interval belongs to the original app and cancels the hold.
    public static func barTakesFocus(barOpen: Bool, voiceHold: Bool, holdOpenedBar: Bool) -> Bool {
        barOpen && !(voiceHold && holdOpenedBar)
    }

    /// The final text becomes a draft. Only an explicit popover action can use it.
    public static func settleFinal(_ final: String) -> String? {
        let text = final.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
