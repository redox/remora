import Foundation

public struct ModelInfo: Codable, Sendable, Equatable {
    public var slug: String
    public var displayName: String
    /// The last `-` component of the slug (`luna`, `terra`, `sol`, `astra`); nil without one.
    public var family: String?
    /// `gpt-6.1-terra` → `[6, 1]`; empty when the slug carries no number.
    public var version: [Int]

    public init(slug: String, displayName: String) {
        self.slug = slug
        self.displayName = displayName
        let parts = slug.split(separator: "-").map(String.init)
        let versionIndex = parts.firstIndex { Self.parseVersion($0) != nil }
        version = versionIndex.flatMap { Self.parseVersion(parts[$0]) } ?? []
        if parts.count > 1, versionIndex != parts.count - 1 { family = parts.last } else { family = nil }
    }

    private static func parseVersion(_ part: String) -> [Int]? {
        guard part.first?.isNumber == true else { return nil }
        let numbers = part.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        return numbers.contains(nil) ? nil : numbers.compactMap { $0 }
    }

    /// Numeric order; a missing component counts as 0 (`[6]` == `[6, 0]`).
    func isOlder(than other: ModelInfo) -> Bool {
        for i in 0..<max(version.count, other.version.count) {
            let a = i < version.count ? version[i] : 0, b = i < other.version.count ? other.version[i] : 0
            if a != b { return a < b }
        }
        return false
    }
}

public struct ResolvedModel: Sendable, Equatable {
    public var slug: String
    /// Shown to the user when the choice differs from what they asked for.
    public var note: String?
    public init(slug: String, note: String? = nil) { self.slug = slug; self.note = note }
}

public enum ModelResolver {
    public static let defaultLarge = "gpt-6.1-terra"
    public static let defaultSmallFamily = "luna"
    static let defaultSmall = "gpt-6-luna"

    /// `.onDevice` has no remote model (nil). `preferred` is the user's pick for the tier, if any.
    public static func resolve(tier: Tier, preferred: String?, catalog: [ModelInfo]) -> ResolvedModel? {
        guard tier != .onDevice else { return nil }
        let preferred = preferred.flatMap { $0.isEmpty ? nil : $0 }
        guard let first = catalog.first else {
            return ResolvedModel(slug: preferred ?? (tier == .small ? defaultSmall : defaultLarge))
        }
        if let preferred {
            if catalog.contains(where: { $0.slug == preferred }) { return ResolvedModel(slug: preferred) }
            let family = ModelInfo(slug: preferred, displayName: preferred).family
            let chosen = family.flatMap { newest(in: catalog, family: $0) } ?? first
            return ResolvedModel(slug: chosen.slug, note: "\(preferred) is no longer available; using \(chosen.slug).")
        }
        switch tier {
        case .small:
            if let luna = newest(in: catalog, family: defaultSmallFamily) { return ResolvedModel(slug: luna.slug) }
            return ResolvedModel(slug: first.slug, note: "No \(defaultSmallFamily) model is available; using \(first.slug).")
        default:
            if catalog.contains(where: { $0.slug == defaultLarge }) { return ResolvedModel(slug: defaultLarge) }
            if let terra = newest(in: catalog, family: "terra") {
                return ResolvedModel(slug: terra.slug, note: "\(defaultLarge) is not available; using \(terra.slug).")
            }
            return ResolvedModel(slug: first.slug, note: "\(defaultLarge) is not available; using \(first.slug).")
        }
    }

    /// The highest version of a family; ties go to the earlier (server-order) model.
    private static func newest(in catalog: [ModelInfo], family: String) -> ModelInfo? {
        var best: ModelInfo?
        for m in catalog where m.family == family {
            if let b = best, !b.isOlder(than: m) { continue }
            best = m
        }
        return best
    }
}
