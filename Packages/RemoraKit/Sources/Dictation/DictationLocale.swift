import Foundation

/// The two dictation languages. One transcriber locale per session.
public enum DictationLocale: String, Codable, Sendable, CaseIterable {
    case fr = "fr-FR", en = "en-US"

    public var locale: Locale { Locale(identifier: rawValue) }
    public var badge: String { self == .fr ? "FR" : "EN" }
    public var name: String { self == .fr ? "French" : "English" }
    public var other: DictationLocale { self == .fr ? .en : .fr }

    /// The first preferred language that is French or English, else English.
    public static func systemDefault(preferredLanguages: [String] = Locale.preferredLanguages) -> DictationLocale {
        for lang in preferredLanguages {
            let code = Locale(identifier: lang).language.languageCode?.identifier
            if code == "fr" { return .fr }
            if code == "en" { return .en }
        }
        return .en
    }
}

public struct DictationSettings: Codable, Sendable, Equatable {
    public static let settingsKey = "dictation.settings"

    public var enabled = false
    public var defaultLocale: DictationLocale
    /// Menu-bar quick switch; nil = Automatic.
    public var pinnedLocale: DictationLocale? = nil
    public var cleanupEnabled = true

    public init(defaultLocale: DictationLocale = .systemDefault()) { self.defaultLocale = defaultLocale }

    private enum CodingKeys: String, CodingKey { case enabled, defaultLocale, pinnedLocale, cleanupEnabled }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        defaultLocale = try c.decodeIfPresent(DictationLocale.self, forKey: .defaultLocale) ?? .systemDefault()
        pinnedLocale = try c.decodeIfPresent(DictationLocale.self, forKey: .pinnedLocale)
        cleanupEnabled = try c.decodeIfPresent(Bool.self, forKey: .cleanupEnabled) ?? true
    }
}

public enum AppKey {
    /// The bundle id, else "name:" + app name, else nil.
    public static func make(bundleID: String?, appName: String?) -> String? {
        if let bundleID, !bundleID.isEmpty { return bundleID }
        if let appName, !appName.isEmpty { return "name:" + appName }
        return nil
    }
}

/// Last dictation language per frontmost app.
public struct LocaleMemory: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var locale: DictationLocale
        public var usedAt: Date
        public init(locale: DictationLocale, usedAt: Date) { self.locale = locale; self.usedAt = usedAt }
    }

    public static let settingsKey = "dictation.localeByApp"
    public static let maxEntries = 200

    public private(set) var entries: [String: Entry]

    public init() { entries = [:] }

    public func locale(for appKey: String?) -> DictationLocale? {
        guard let appKey else { return nil }
        return entries[appKey]?.locale
    }

    public mutating func record(_ l: DictationLocale, for appKey: String?, at date: Date) {
        guard let appKey else { return }
        entries[appKey] = Entry(locale: l, usedAt: date)
        if entries.count > Self.maxEntries {
            let overflow = entries.count - Self.maxEntries
            let oldest = entries.sorted { ($0.value.usedAt, $0.key) < ($1.value.usedAt, $1.key) }.prefix(overflow)
            for (k, _) in oldest { entries[k] = nil }
        }
    }

    public mutating func forgetAll() { entries = [:] }
}

public enum LocaleChooser {
    /// Quick switch, then the app's last language, then the Settings default.
    public static func choose(pinned: DictationLocale?, appKey: String?, memory: LocaleMemory,
                              defaultLocale: DictationLocale) -> DictationLocale {
        pinned ?? memory.locale(for: appKey) ?? defaultLocale
    }
}
