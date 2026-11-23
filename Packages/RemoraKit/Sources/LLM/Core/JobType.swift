import Foundation

public enum Tier: String, Codable, Sendable, CaseIterable { case onDevice = "on_device", small, large }

public enum JobType: String, Codable, Sendable, CaseIterable {
    case dictationCleanup = "dictation_cleanup"
    case queryExpansion = "query_expansion"
    case workingMemory = "working_memory"
    case salientFlags = "salient_flags"
    case entityExtraction = "entity_extraction"
    case hourChronicle = "hour_chronicle"
    case timeLedgerAttribution = "time_ledger_attribution"
    case nudgeTriage = "nudge_triage"
    case evidenceCheck = "evidence_check"
    case rewrite
    case editMode = "edit_mode"
    case chat
    case dayRollup = "day_rollup"
    case weekRollup = "week_rollup"
    case monthRollup = "month_rollup"
    case yearRollup = "year_rollup"
    case wikiWriteup = "wiki_writeup"
    case identity
    case styleConsolidation = "style_consolidation"
    case morningBrief = "morning_brief"
    case eveningWrap = "evening_wrap"
    case nudgeWrite = "nudge_write"
    case memoryDigest = "memory_digest"
    case chatFold = "chat_fold"
    case reminderPrompt = "reminder_prompt"

    /// Default routing before user overrides and privacy checks.
    public var defaultTier: Tier {
        switch self {
        // No job defaults to on-device (Luna is cheap); it stays selectable per job and is the
        // only route for calls that may not use the cloud.
        case .dictationCleanup, .queryExpansion, .workingMemory,
             .salientFlags, .entityExtraction, .hourChronicle, .timeLedgerAttribution, .nudgeTriage, .evidenceCheck,
             .chatFold: return .small
        default: return .large
        }
    }

    /// Background jobs yield to the usage-limit backoff; foreground ones (the user is waiting)
    /// never do.
    public var isBackground: Bool {
        switch self {
        case .rewrite, .editMode, .chat, .dictationCleanup, .queryExpansion, .chatFold: false
        default: true
        }
    }

    /// nil (omit `reasoning`) for chat; low for everything else.
    public var defaultEffort: ReasoningEffort? { self == .chat ? nil : .low }
}
