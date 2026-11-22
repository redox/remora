import Foundation

public enum ExclusionRule: Sendable, Equatable {
    case domain(String), app(String), title(String), url(String), path(String)

    /// Parses a user-entered pattern. Returns nil for empty or malformed input.
    public init?(pattern: String) {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let colon = trimmed.firstIndex(of: ":") {
            let prefix = trimmed[..<colon].lowercased()
            let value = trimmed[trimmed.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let make: ((String) -> ExclusionRule)? = switch prefix {
            case "app": { .app(AppName.normalize($0)) }
            case "title": { .title(AppName.stripFormatting($0)) }
            case "url": { .url(AppName.stripFormatting($0)) }
            case "path": { .path(AppName.stripFormatting($0)) }
            default: nil
            }
            if let make {
                guard !value.isEmpty else { return nil }
                if prefix == "app", AppName.normalize(value).isEmpty { return nil }
                self = make(value)
                return
            }
        }
        guard let d = Self.normalizeDomain(trimmed) else { return nil }
        self = .domain(d)
    }

    private static func normalizeDomain(_ raw: String) -> String? {
        var s = raw.lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let slash = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            s = String(s[..<slash])
        }
        if let colon = s.firstIndex(of: ":") {
            // Only a numeric port may follow; anything else is a mistyped prefix ("tilte:x").
            let port = s[s.index(after: colon)...]
            guard !port.isEmpty, port.allSatisfy(\.isASCII), port.allSatisfy(\.isNumber) else { return nil }
            s = String(s[..<colon])
        }
        if s.hasPrefix("*.") { s.removeFirst(2) }
        while s.hasPrefix(".") { s.removeFirst() }
        while s.hasSuffix(".") { s.removeLast() }
        guard !s.isEmpty, !s.contains(where: \.isWhitespace) else { return nil }
        return s
    }

    public var pattern: String {
        switch self {
        case .domain(let v): v
        case .app(let v): "app:\(v)"
        case .title(let v): "title:\(v)"
        case .url(let v): "url:\(v)"
        case .path(let v): "path:\(v)"
        }
    }

    public var supportsManualSaves: Bool {
        switch self {
        case .app, .domain: true
        case .title, .url, .path: false
        }
    }

    public func matches(_ ctx: WindowContext) -> Bool {
        switch self {
        case .domain(let d):
            guard let host = ctx.domain else { return false }
            return Self.host(host, matchesDomain: d.lowercased())
        case .app(let a):
            return AppName.fold(AppName.normalize(ctx.app)) == AppName.fold(AppName.normalize(a))
        case .title(let t):
            return Self.contains(ctx.windowTitle, t)
        case .url(let u):
            return Self.contains(ctx.url?.absoluteString, u)
        case .path(let p):
            return Self.contains(ctx.filePath, p)
        }
    }

    /// Case-insensitive substring test that is locale-independent (fixed POSIX case folding,
    /// no `localized*` comparison) and blind to invisible format characters on both sides.
    static func contains(_ haystack: String?, _ needle: String) -> Bool {
        guard let haystack else { return false }
        let n = AppName.foldForMatching(needle)
        return !n.isEmpty && AppName.foldForMatching(haystack).contains(n)
    }

    public static func host(_ host: String, matchesDomain d: String) -> Bool {
        host == d || host.hasSuffix("." + d)
    }
}
