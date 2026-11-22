import Foundation

public enum UpdatesDisabledReason: Equatable, Sendable {
    case debugBuild, missingFeed, invalidFeed, missingKey, invalidKey
    /// Otherwise ready, but the running copy is not in /Applications or ~/Applications (or is translocated).
    case notInstalled
}

/// Whether the updater may start. Anything incomplete, unexpanded or malformed disables updates (fail closed).
///
/// **Contract (Task 4 relies on this):** the app must never create the Sparkle updater (`SPUUpdater` /
/// `SPUStandardUpdaterController`) or call `startUpdater` unless `evaluate` returns `.ready`. Info.plist ships
/// `SUEnableAutomaticChecks` and `SUAutomaticallyUpdate` = true, so an updater created with the placeholder feed
/// (`https://github.com//releases/...`) or an empty `SUPublicEDKey` would start checking on its own.
/// Use `repositoryURL(_:)` to decide whether to show "view repository" links.
public enum UpdateConfiguration: Equatable, Sendable {
    case ready(feed: URL)
    case disabled(UpdatesDisabledReason)

    /// Ed25519 public keys are 32 bytes.
    public static let publicKeyLength = 32

    /// Checks, in order: debug build, missing feed, invalid feed, missing key, invalid key, not installed.
    /// `isInstalled` is `InstallLocation.classify(...).isInstalled` for the running bundle: like Goldfish, only a copy
    /// in an Applications folder (never a translocated one) updates itself.
    public static func evaluate(feedURL: String?, publicKey: String?, isDebugBuild: Bool,
                                isInstalled: Bool) -> UpdateConfiguration {
        if isDebugBuild { return .disabled(.debugBuild) }
        let feed = trimmed(feedURL)
        if feed.isEmpty { return .disabled(.missingFeed) }
        guard let url = validHTTPSURL(feed) else { return .disabled(.invalidFeed) }
        let key = trimmed(publicKey)
        if key.isEmpty { return .disabled(.missingKey) }
        guard let bytes = Data(base64Encoded: key), bytes.count == publicKeyLength else { return .disabled(.invalidKey) }
        if !isInstalled { return .disabled(.notInstalled) }
        return .ready(feed: url)
    }

    /// The project's repository page (`https://<host>/<owner>/<name>`), or nil while it is empty or a placeholder.
    public static func repositoryURL(_ string: String?) -> URL? {
        guard let url = validHTTPSURL(trimmed(string)), url.pathComponents.dropFirst().count == 2 else { return nil }
        return url
    }

    /// An `https` URL with a host and a non-empty path whose segments are all non-empty.
    /// Rejects unexpanded build settings such as `$(REMORA_GITHUB_REPO)` and the `//` an empty repo leaves behind.
    static func validHTTPSURL(_ string: String) -> URL? {
        guard !string.isEmpty, !string.contains("$("), !string.contains(where: \.isWhitespace),
              let components = URLComponents(string: string),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil
        else { return nil }
        let path = components.percentEncodedPath
        guard path.hasPrefix("/") else { return nil }
        let segments = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.isEmpty, segments.allSatisfy({ !$0.isEmpty }) else { return nil }
        return components.url
    }

    private static func trimmed(_ string: String?) -> String {
        (string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
