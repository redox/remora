import ChatBar
import Dictation
import Foundation
import GRDB
import Input
import Storage

/// A value the setting does not accept. `allowed` is the entry's human description.
public struct SettingValueError: Error, Equatable, Sendable, LocalizedError {
    public let name: String
    public let allowed: String
    public init(name: String, allowed: String) { self.name = name; self.allowed = allowed }
    public var errorDescription: String? { "Invalid value for \(name). Allowed: \(allowed)." }
}

/// The only settings the chat may change (`update_setting`). Privacy-critical settings are not
/// here and cannot be reached: exclusions (the chat can only add one, never remove it), the capture
/// pause (its own tool), delete-all, the account, MCP and client configs. The two entries that
/// reduce or extend what Remora keeps (`background_memory`, `raw_capture_retention`) always ask.
///
/// Every accessor takes the caller's connection: writes run inside `DataGeneration.write`, where
/// GRDB is not reentrant. An unreadable stored value reads as its default, as the app does.
public struct SettingRegistry: Sendable {
    public struct Entry: Sendable {
        public let name: String
        /// Human description of the accepted values, for the tool schema and errors.
        public let values: String
        public let risk: ActionRisk
        /// The current value, in the same spelling `set` accepts.
        public let get: @Sendable (SettingsStore, Database) throws -> String
        /// Validates, then stores. Throws `SettingValueError` for a bad value (nothing written).
        public let set: @Sendable (SettingsStore, Database, String) throws -> Void
        /// The canonical spelling of an accepted value; throws `SettingValueError` otherwise.
        public let validate: @Sendable (String) throws -> String
        /// Stores any value `get` can return (undo), even one the model may not choose, such as a
        /// 45-day retention set in Settings.
        public let restore: @Sendable (SettingsStore, Database, String) throws -> Void
    }

    /// Settings › Notifications "Proactive messages" (pinned key; default on).
    public static let proactiveEnabledKey = "proactive.enabled"
    public static let retentionDays = [7, 14, 30, 60, 90, 180, 365]
    public static let budgetRange = 100_000...5_000_000

    public static let entries: [Entry] = [
        onOff("proactive_messages", .reversible,
              read: { s, d in (try? s.value(Bool.self, forKey: proactiveEnabledKey, in: d)) ?? true },
              write: { s, d, v in try s.setValue(v, forKey: proactiveEnabledKey, in: d) }),
        make("bar_position", values: BarPosition.allCases.map(\.rawValue).joined(separator: ", "), risk: .reversible,
             parse: { BarPosition(rawValue: $0) }, format: \.rawValue,
             read: { s, d in bar(s, d).position },
             write: { s, d, v in try updateBar(s, d) { $0.position = v } }),
        onOff("open_on_hover", .reversible, read: { s, d in bar(s, d).openOnHover },
              write: { s, d, v in try updateBar(s, d) { $0.openOnHover = v } }),
        onOff("auto_hide_bar", .reversible, read: { s, d in bar(s, d).autoHide },
              write: { s, d, v in try updateBar(s, d) { $0.autoHide = v } }),
        onOff("dim_bar_when_unfocused", .reversible, read: { s, d in bar(s, d).dimWhenUnfocused },
              write: { s, d, v in try updateBar(s, d) { $0.dimWhenUnfocused = v } }),
        make("text_size", values: "100 to 150 (percent) in steps of 10", risk: .reversible,
             parse: { Int($0).flatMap { (100...150).contains($0) && $0 % 10 == 0 ? $0 : nil } },
             format: { String($0) },
             read: { s, d in Int((bar(s, d).textScale * 100).rounded()) },
             write: { s, d, v in try updateBar(s, d) { $0.textScale = Double(v) / 100 } }),
        onOff("sounds", .reversible,
              read: { s, d in shortcuts(s, d).soundsEnabled },
              write: { s, d, v in
                  var x = shortcuts(s, d)
                  x.soundsEnabled = v
                  try s.setValue(x, forKey: ShortcutSettings.settingsKey, in: d)
              }),
        onOff("window_badge", .reversible,
              read: { s, d in (try? s.windowBadgeEnabled(in: d)) ?? false },
              write: { s, d, v in try s.setWindowBadgeEnabled(v, in: d) }),
        onOff("dictation", .reversible,
              read: { s, d in dictation(s, d).enabled },
              write: { s, d, v in
                  var x = dictation(s, d)
                  x.enabled = v
                  try s.setValue(x, forKey: DictationSettings.settingsKey, in: d)
              }),
        make("memory_language", values: "en, fr", risk: .reversible,
             parse: { MemoryLanguage(rawValue: $0) }, format: \.rawValue,
             read: { s, d in (try? s.value(MemoryLanguage.self, forKey: MemorySettings.languageKey, in: d)) ?? .en },
             write: { s, d, v in try MemorySettings(s).setLanguage(v, in: d) }),
        onOff("background_memory", .confirm,
              read: { s, d in (try? s.value(Bool.self, forKey: MemorySettings.enabledKey, in: d)) ?? true },
              write: { s, d, v in try MemorySettings(s).setEnabled(v, in: d) }),
        make("raw_capture_retention", values: retentionDays.map(String.init).joined(separator: ", ") + " (days) or forever",
             risk: .confirm,
             parse: { retention($0, allowed: { retentionDays.contains($0) }) },
             lenient: { retention($0, allowed: { RetentionSetting.dayRange.contains($0) }) },
             format: { r in if case .days(let n) = r { String(n) } else { "forever" } },
             read: { s, d in
                 switch (try? s.value(RetentionSetting.self, forKey: MemorySettings.retentionKey, in: d)) ?? nil {
                 case .days(let n)?: .days(clamping: n)
                 case .forever?: .forever
                 case nil: MemorySettings.defaultRetention
                 }
             },
             write: { s, d, v in try MemorySettings(s).setRetention(v, in: d) }),
        make("daily_background_budget",
             values: "\(budgetRange.lowerBound) to \(budgetRange.upperBound) tokens per day", risk: .reversible,
             parse: { Int($0).flatMap { budgetRange.contains($0) ? $0 : nil } },
             lenient: { Int($0).flatMap { $0 > 0 ? $0 : nil } },
             format: { String($0) },
             read: { s, d in
                 let v = (try? s.value(Int.self, forKey: MemorySettings.dailyTokenBudgetKey, in: d)) ?? nil
                 return v.flatMap { $0 > 0 ? $0 : nil } ?? MemorySettings.defaultDailyTokenBudget
             },
             write: { s, d, v in try MemorySettings(s).setDailyTokenBudget(v, in: d) }),
    ]

    public static func entry(_ name: String) -> Entry? { entries.first { $0.name == name } }

    // MARK: Builders

    private static func make<V>(_ name: String, values: String, risk: ActionRisk,
                                parse: @escaping @Sendable (String) -> V?,
                                lenient: (@Sendable (String) -> V?)? = nil,
                                format: @escaping @Sendable (V) -> String,
                                read: @escaping @Sendable (SettingsStore, Database) -> V,
                                write: @escaping @Sendable (SettingsStore, Database, V) throws -> Void) -> Entry {
        let bad = SettingValueError(name: name, allowed: values)
        let strict: @Sendable (String) throws -> V = { raw in
            guard let v = parse(normalize(raw)) else { throw bad }
            return v
        }
        let loose = lenient ?? parse
        return Entry(
            name: name, values: values, risk: risk,
            get: { s, d in format(read(s, d)) },
            set: { s, d, raw in try write(s, d, try strict(raw)) },
            validate: { raw in format(try strict(raw)) },
            restore: { s, d, raw in
                guard let v = loose(normalize(raw)) else { throw bad }
                try write(s, d, v)
            })
    }

    private static func onOff(_ name: String, _ risk: ActionRisk,
                              read: @escaping @Sendable (SettingsStore, Database) -> Bool,
                              write: @escaping @Sendable (SettingsStore, Database, Bool) throws -> Void) -> Entry {
        make(name, values: "on, off", risk: risk,
             parse: { $0 == "on" ? true : $0 == "off" ? false : nil },
             format: { $0 ? "on" : "off" }, read: read, write: write)
    }

    private static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func retention(_ raw: String, allowed: (Int) -> Bool) -> RetentionSetting? {
        if raw == "forever" { return .forever }
        guard let n = Int(raw), allowed(n) else { return nil }
        return .days(n)
    }

    // MARK: Composite settings (one JSON value per pane: change one field, keep the others)

    private static func bar(_ s: SettingsStore, _ d: Database) -> BarSettings {
        ((try? s.value(BarSettings.self, forKey: BarSettings.key, in: d)) ?? nil) ?? BarSettings()
    }

    private static func updateBar(_ s: SettingsStore, _ d: Database, _ change: (inout BarSettings) -> Void) throws {
        var b = bar(s, d)
        change(&b)
        try s.setValue(b, forKey: BarSettings.key, in: d)
    }

    private static func shortcuts(_ s: SettingsStore, _ d: Database) -> ShortcutSettings {
        ((try? s.value(ShortcutSettings.self, forKey: ShortcutSettings.settingsKey, in: d)) ?? nil) ?? ShortcutSettings()
    }

    private static func dictation(_ s: SettingsStore, _ d: Database) -> DictationSettings {
        ((try? s.value(DictationSettings.self, forKey: DictationSettings.settingsKey, in: d)) ?? nil) ?? DictationSettings()
    }
}
