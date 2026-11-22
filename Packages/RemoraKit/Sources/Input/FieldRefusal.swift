import Capture
import Foundation

/// Why the focused element is not offered to the rewrite key. Carries no field content.
public enum FieldRefusal: Sendable, Equatable {
    /// Nothing is focused, or the focused element has no readable text, selection or caret.
    case noFocusedElement
    /// Remora's own UI is focused or frontmost.
    case ownApp
    /// A password field: its value is never read.
    case secureField
    /// A password manager (built-in skip list): nothing of it is read.
    case passwordManager
    /// The app did not answer within the messaging timeout.
    case notResponding

    /// The refusal for an element, from its identity alone (checked before any of its text is read).
    /// `identifier` is the element's AX identifier: the onboarding practice field
    /// (`practiceFieldIdentifier`), and only when it lives in Remora's own process, is the one
    /// element of Remora's UI the rewrite key may read. Password fields stay refused.
    public static func check(fieldBundleID: String?, fieldPID: pid_t, frontmostBundleID: String?, ownPID: pid_t,
                             ownBundleID: String?, role: String?, subrole: String?,
                             identifier: String? = nil) -> FieldRefusal? {
        let practice = fieldPID == ownPID && allowsOwnApp(identifier: identifier)
        if !practice {
            if fieldPID == ownPID { return .ownApp }
            if let own = ownBundleID, frontmostBundleID == own || fieldBundleID == own { return .ownApp }
        }
        for id in [fieldBundleID, frontmostBundleID] {
            if let id, BuiltInSkipList.bundleIDs.contains(id) { return .passwordManager }
        }
        if role == secureRole || subrole == secureRole { return .secureField }
        return nil
    }

    static let secureRole = "AXSecureTextField"

    /// The AX identifier of the onboarding "Try the key" box.
    public static let practiceFieldIdentifier = "dev.remora.practice"

    /// True only for the onboarding practice field.
    public static func allowsOwnApp(identifier: String?) -> Bool { identifier == practiceFieldIdentifier }
}

/// The result of reading the focused element.
public enum FocusedFieldRead: Sendable {
    case field(FocusedField)
    case refused(FieldRefusal)

    public var field: FocusedField? {
        if case .field(let f) = self { f } else { nil }
    }
}
