import Foundation

/// When to refresh: at `earliest_refresh_at` (or five minutes before expiry when the server gave none),
/// and never later than one minute before expiry.
public enum RefreshPolicy {
    public static func isDue(_ t: SIWCTokens, now: Date) -> Bool {
        let preferred = t.earliestRefreshAt ?? t.expiresAt.addingTimeInterval(-300)
        return now >= min(preferred, t.expiresAt.addingTimeInterval(-60))
    }
}

public enum SignInState: Sendable, Equatable {
    case signedOut
    case signedIn(email: String?, planUsageEnabled: Bool)
    /// The session ended (terminal refresh error): sign in again; the registration is kept.
    case needsSignIn
    /// The credential store could not be read (e.g. the keychain is locked): the session is unknown.
    case unavailable
}
