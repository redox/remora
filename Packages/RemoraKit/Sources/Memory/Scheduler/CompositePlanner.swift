import Foundation
import os
import Storage

/// Runs several planners (plan 4's `JobPlanner`, plan 5's proactive planner) as one: their specs
/// and requeues are concatenated in order. Only `JobPlanner` owns `memory.plannerWatermark`, so
/// the watermark is taken from it alone; any other planner's watermark is ignored. A planner that
/// throws is logged by type and error code (`MemoryScheduler.code(for:)`, never a description) and skipped, so one failing planner never stops the others. Like every
/// planner it performs no writes: the scheduler commits the merged plan in one transaction.
public struct CompositePlanner: JobPlanning {
    private static let log = Logger(subsystem: "dev.remora", category: "memory")
    private let planners: [any JobPlanning]

    public init(_ planners: [any JobPlanning]) { self.planners = planners }

    public func plan(_ s: SchedulerSignals) throws -> JobPlan {
        var merged = JobPlan()
        for planner in planners {
            let plan: JobPlan
            do {
                plan = try planner.plan(s)
            } catch {
                let type = String(describing: Swift.type(of: planner))
                let code = MemoryScheduler.code(for: error)
                Self.log.error("planner \(type, privacy: .public) failed: \(code, privacy: .public)")
                continue
            }
            merged.specs += plan.specs
            merged.requeues += plan.requeues
            if planner is JobPlanner { merged.watermark = plan.watermark }
        }
        return merged
    }
}
