import Foundation

/// What Settings › Account and the menu show for a `SignInState`. Pure, so it is unit-tested.
public struct AccountPresentation: Sendable, Equatable {
    public enum Section: Sendable, Equatable {
        /// The credential store (Keychain) could not be read: Retry, never the sign-in button.
        case unavailable
        case signedOut
        /// The session ended; the registration is kept.
        case needsSignIn
        /// Signed in, but the sign-in lacks the plan-usage scope.
        case planUsageMissing(email: String?)
        case signedIn(email: String?)
    }

    public let section: Section

    public init(_ state: SignInState) {
        switch state {
        case .unavailable: section = .unavailable
        case .signedOut: section = .signedOut
        case .needsSignIn: section = .needsSignIn
        case .signedIn(let email, let planUsage): section = planUsage ? .signedIn(email: email) : .planUsageMissing(email: email)
        }
    }

    /// "Continue with ChatGPT" is offered only when there is no working sign-in (a re-run with the full
    /// scopes is also offered when plan usage is missing). Never while signed in, so a second account
    /// cannot replace the first without signing out.
    public var offersContinue: Bool {
        switch section {
        case .signedOut, .needsSignIn, .planUsageMissing: return true
        case .unavailable, .signedIn: return false
        }
    }

    public var offersSignOut: Bool {
        switch section {
        case .needsSignIn, .planUsageMissing, .signedIn: return true
        case .unavailable, .signedOut: return false
        }
    }

    public var offersRetry: Bool { section == .unavailable }

    /// The second menu-bar status line.
    public var menuLine: String {
        switch section {
        case .unavailable: return "ChatGPT: can't read sign-in"
        case .signedOut: return "ChatGPT: not signed in"
        case .needsSignIn: return "ChatGPT: sign in again"
        case .planUsageMissing: return "ChatGPT: plan usage off"
        case .signedIn: return "ChatGPT: signed in"
        }
    }

    public var isSignedInWithPlanUsage: Bool {
        if case .signedIn = section { return true }
        return false
    }

    public static let unavailableMessage = "Can't read your sign-in from the Keychain"
    public static let signedOutExplainer = "Use your ChatGPT plan in Remora. Requests count against your ChatGPT plan's usage, not a separate bill."
    public static let needsSignInMessage = "Your ChatGPT sign-in expired. Continue with ChatGPT to reconnect."
    public static let planUsageMissingMessage = "Plan usage isn't enabled for this sign-in. Remora can't make requests."

    /// A user-facing line for a failed sign-in; nil for a cancellation (the user did it). Never includes
    /// tokens, codes or server text.
    public static func message(for error: any Error) -> String? {
        if error is CancellationError { return nil }
        if let e = error as? AuthError {
            switch e {
            case .identityMismatch: return "Sign out first to switch ChatGPT accounts."
            case .accessDenied: return "Sign-in was declined in the browser."
            case .browserUnavailable: return "Remora could not open your browser."
            case .listenerFailed: return "Remora could not start its local sign-in listener."
            case .timedOut: return "Sign-in timed out. Try again."
            case .missingRequiredScope: return "This sign-in doesn't include plan usage. Try again and allow Remora access."
            case .stateMismatch, .issuerMismatch, .clientIDMismatch, .registrationIncomplete, .missingIDToken,
                 .idToken, .authorizationFailed:
                return "Sign-in could not be verified. Try again."
            case .terminalRefresh, .invalidClient, .tokenEndpoint:
                return "ChatGPT did not accept the sign-in. Try again."
            }
        }
        if let e = error as? LLMError {
            switch e {
            case .temporarilyUnavailable(let code) where code == "credential_store": return unavailableMessage + "."
            case .temporarilyUnavailable, .transport: return "Could not reach ChatGPT. Check your connection and try again."
            case .cancelled: return nil
            default: return "Sign-in failed. Try again."
            }
        }
        return "Sign-in failed. Try again."
    }
}
