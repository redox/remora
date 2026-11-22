import Foundation
import Storage

/// What an undo did.
public enum UndoResult: Sendable, Equatable {
    case done
    /// The value was changed after the action (by the user or another action): left as it is.
    case changedSince

    /// A line for the chat, when the undo did nothing.
    public var message: String? {
        switch self {
        case .done: nil
        case .changedSince: "This was changed since, so it was left as it is."
        }
    }
}

extension ActionTools {
    public struct UnknownSetting: Error, Equatable, Sendable {}

    /// Undoes an action from its receipt's token, restoring the state it replaced:
    /// - `removeExclusion` removes only the exclusion that action created (an exclusion that was
    ///   already there gets no token);
    /// - `restorePause` puts back the previous `pausedUntil` (nil resumes), only while the pause is
    ///   still the one the action set;
    /// - `cancelReminder` / `reactivateReminder` cancel a created reminder or revive a cancelled one;
    /// - `restoreSetting` writes the previous value (even one the model could not have chosen), only
    ///   while the setting still has the value the action applied.
    /// A pause or setting changed since is left alone (`.changedSince`, nothing written).
    ///
    /// Writes run in `DataGeneration.write(expected:)` with `generation` (the receipt's), so an undo
    /// after a delete-all throws `DataGeneration.Stale` and changes nothing; nil reads it now.
    @discardableResult
    public static func perform(_ u: UndoToken, generation: Int? = nil, reminders: ReminderEngine, db: AppDatabase,
                               effects: any ActionEffects) async throws -> UndoResult {
        let expected = try generation ?? DataGeneration.current(db)
        let change: ActionChange
        switch u {
        case .removeExclusion(let pattern):
            try DataGeneration.write(db, expected: expected) { d in _ = try ExclusionStore.remove(pattern, in: d) }
            change = .exclusions
        case .restorePause(let previous, let applied):
            let settings = SettingsStore(db)
            let restored = try DataGeneration.write(db, expected: expected) { d in
                guard try settings.pausedUntil(in: d) == applied else { return false }
                try settings.pause(until: previous, in: d)
                return true
            }
            guard restored else { return changedSince() }
            change = .pause
        case .cancelReminder(let id):
            _ = try await reminders.cancel(id, expected: expected)
            change = .reminders
        case .reactivateReminder(let id):
            _ = try await reminders.reactivate(id, expected: expected)
            change = .reminders
        case .restoreSetting(let name, let previous, let applied):
            guard let entry = SettingRegistry.entry(name) else { throw UnknownSetting() }
            let settings = SettingsStore(db)
            let restored = try DataGeneration.write(db, expected: expected) { d in
                guard try entry.get(settings, d) == applied else { return false }
                try entry.restore(settings, d, previous)
                return true
            }
            guard restored else { return changedSince() }
            change = .setting(name)
        }
        await effects.didChange(change)
        log.info("undo done")
        return .done
    }

    private static func changedSince() -> UndoResult {
        log.info("undo skipped: changed since")
        return .changedSince
    }
}
