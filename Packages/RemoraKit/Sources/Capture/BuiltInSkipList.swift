import Foundation

public enum BuiltInSkipList {
    /// Password managers: never captured regardless of user settings.
    public static let bundleIDs: Set<String> = [
        "com.1password.1password",
        "com.bitwarden.desktop",
        "com.apple.Passwords",
        "com.apple.keychainaccess",
        "org.keepassxc.keepassxc",
        "com.agilebits.onepassword7",  // 1Password 7
        "me.proton.pass.electron",  // Proton Pass
        "in.sinew.Enpass-Desktop",  // Enpass
        "com.hicknhacksoftware.MacPass",
        "com.markmcguill.strongbox",
    ]

    /// Banking domains and password-manager web vaults, matched like `ExclusionRule.domain`
    /// (the domain itself or any subdomain). `"bank"` is the `.bank` TLD, reserved for verified
    /// banks: any host ending in `.bank`.
    public static let domains: [String] = [
        "bank",
        "boursorama.com", "credit-agricole.fr", "bnpparibas.net", "mabanque.bnpparibas",
        "societegenerale.fr", "labanquepostale.fr", "lcl.fr", "caisse-epargne.fr",
        "banquepopulaire.fr", "creditmutuel.fr", "fortuneo.fr", "hellobank.fr",
        "qonto.com", "revolut.com", "n26.com", "wise.com", "paypal.com", "chase.com",
        "bankofamerica.com", "wellsfargo.com", "americanexpress.com",
    ] + passwordVaultDomains

    /// Password-manager web vaults: treated like password-manager apps (nothing of them is read).
    public static let passwordVaultDomains: [String] = [
        "my.1password.com", "my.1password.eu", "my.1password.ca", "vault.bitwarden.com",
        "vault.bitwarden.eu", "app.dashlane.com", "lastpass.com", "keepersecurity.com",
        "pass.proton.me",
    ]

    /// The host is a password-manager web vault (or a subdomain of one).
    public static func isPasswordVault(host: String?) -> Bool {
        guard let host else { return false }
        return passwordVaultDomains.contains { ExclusionRule.host(host, matchesDomain: $0) }
    }

    /// Sign-in and account-recovery URL path segments. A page is skipped when any whole path
    /// segment (with or without an extension) equals one of these.
    public static let signInPathSegments: Set<String> = [
        "login", "signin", "sign-in", "sign_in", "logon", "auth", "oauth", "authorize", "sso",
        "saml", "password", "reset-password", "forgot-password", "recover", "recovery", "2fa",
        "mfa", "otp", "verify", "two-factor",
    ]

    /// Checks the URL path and, for hash-routed single-page apps (`/#/login`, `/#!/login`),
    /// a fragment that starts with `/`.
    public static func isSignInURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        if hasSignInSegment(url.path(percentEncoded: false)) { return true }
        guard var fragment = url.fragment(percentEncoded: false) else { return false }
        if fragment.hasPrefix("!") { fragment.removeFirst() }
        guard fragment.hasPrefix("/") else { return false }
        return hasSignInSegment(String(fragment.prefix { $0 != "?" }))
    }

    private static func hasSignInSegment(_ path: String) -> Bool {
        path.lowercased().split(separator: "/").contains { segment in
            if signInPathSegments.contains(String(segment)) { return true }
            guard let dot = segment.lastIndex(of: "."), dot != segment.startIndex else { return false }
            return signInPathSegments.contains(String(segment[..<dot]))
        }
    }
}
