import Foundation

/// Where `remora-mcp` lives, and whether it may be written into a client's config. A path inside
/// a translocated copy (macOS App Translocation) disappears when Remora quits, and a missing or
/// non-executable tool would register a server that cannot start.
public enum ServerLocation {
    public static let translocatedMessage =
        "Remora is running from a temporary location (macOS App Translocation). Move it to Applications and open it again before connecting."
    public static let missingToolMessage =
        "This copy of Remora has no runnable remora-mcp tool, so it can't be connected."

    /// `<bundle>/Contents/MacOS/remora-mcp`, with symlinks in the bundle path resolved.
    public static func toolPath(bundleURL: URL) -> String {
        bundleURL.resolvingSymlinksInPath().appendingPathComponent("Contents/MacOS/remora-mcp").path
    }

    /// Why Connect and Update are refused, or nil when they may run.
    public static func refusal(bundlePath: String, toolIsExecutable: Bool) -> String? {
        if bundlePath.range(of: "/AppTranslocation/", options: .caseInsensitive) != nil { return translocatedMessage }
        if !toolIsExecutable { return missingToolMessage }
        return nil
    }

    /// The single guard for writing Remora into a client's config: not installed in Applications
    /// (`notInstalledMessage`, the app's caption) wins; then translocation and a missing tool.
    public static func refusal(isInstalled: Bool, notInstalledMessage: String,
                               bundlePath: String, toolIsExecutable: Bool) -> String? {
        guard isInstalled else { return notInstalledMessage }
        return refusal(bundlePath: bundlePath, toolIsExecutable: toolIsExecutable)
    }
}
