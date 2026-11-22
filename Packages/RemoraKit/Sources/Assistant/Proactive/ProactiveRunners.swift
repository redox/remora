import Capture
import Foundation
import LLM
import Memory
import Storage

/// The proactive job runners: the morning brief, the evening wrap-up and the nudge scan. Each
/// reads the proactive switch fresh (`ProactiveSettings`). With `MemoryRunners`, every `JobKind`.
public enum ProactiveRunners {
    /// `canInterrupt`: false when the user is idle over 600 s or sharing the screen.
    public static func make(db: AppDatabase, llm: LLMService, inbox: ProactiveInbox,
                            policy: @escaping @Sendable () -> CapturePolicy,
                            canInterrupt: @escaping @Sendable () async -> Bool) -> [JobKind: any JobRunner] {
        let writer = VerifiedWriter(llm: llm)
        let settings = SettingsStore(db)
        let enabled: @Sendable () -> Bool = { ProactiveSettings.enabled(settings) }
        return [
            .morningBrief: BriefRunner(kind: .morning, db: db, writer: writer, inbox: inbox, enabled: enabled),
            .eveningWrap: BriefRunner(kind: .evening, db: db, writer: writer, inbox: inbox, enabled: enabled),
            .nudgeScan: NudgeRunner(db: db, llm: llm, writer: writer, inbox: inbox, policy: policy, enabled: enabled,
                                    canInterrupt: canInterrupt),
            .routineScan: RoutineScanRunner(db: db, inbox: inbox),
        ]
    }
}
