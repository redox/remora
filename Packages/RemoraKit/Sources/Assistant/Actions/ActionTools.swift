import Capture
import Foundation
import GRDB
import LLM
import MCP
import Redaction
import Storage
import Synchronization
import os

/// The chat's action tools. Each one validates its arguments, builds an `ActionProposal`, asks the
/// user when `ActionPolicy` says so (always for `confirm` risks, and for every action once the turn
/// read untrusted data), then writes inside `DataGeneration.write(expected:)` under the turn's
/// generation, so an action confirmed after a delete-all writes nothing. Outputs are JSON with a
/// `status` of `done`, `declined_by_user` or `confirmation_expired` (neither is an error). Never
/// logs arguments or outputs: tool names and statuses only.
public enum ActionTools {
    /// A confirmation card answered later than this (or not at all) runs nothing.
    public static let confirmationLifetime: TimeInterval = 600

    /// `now` is the wall clock used for expiry and for action times; `confirmTimeout` stops waiting
    /// for an unanswered card (tests shorten it).
    public static func all(reminders: ReminderEngine, db: AppDatabase, effects: any ActionEffects,
                           now: @escaping @Sendable () -> Date = Date.init,
                           confirmTimeout: Duration = .seconds(confirmationLifetime)) -> [any ChatTool] {
        let deps = ActionDeps(reminders: reminders, db: db, effects: effects, now: now, confirmTimeout: confirmTimeout)
        return [
            CreateReminderTool(deps: deps), ListRemindersTool(deps: deps), CancelReminderTool(deps: deps),
            AddExclusionTool(deps: deps), PauseCaptureTool(deps: deps), UpdateIdentityTool(deps: deps),
            UpdateSettingTool(deps: deps), CorrectWikiTool(deps: deps), UpdateRoutineTool(deps: deps),
            ForgetSnapshotsTool(deps: deps),
        ]
    }

    static let log = Logger(subsystem: "dev.remora", category: "chat")
}

// MARK: - Shared machinery

struct ActionDeps: Sendable {
    let reminders: ReminderEngine
    let db: AppDatabase
    let effects: any ActionEffects
    let now: @Sendable () -> Date
    let confirmTimeout: Duration
}

/// What a confirmed (or unasked) action runs with.
struct PerformContext: Sendable {
    /// The data generation the write must still be under.
    let generation: Int
    /// The time the action runs (not when its card was built).
    let now: Date
    /// The user accepted the card.
    let confirmed: Bool
}

/// The user's answer to a card: the first of accept, decline or timeout wins.
final class CardAnswer: Sendable {
    enum Value: Sendable { case accepted, declined, expired }
    private struct S {
        var value: Value?
        var waiter: CheckedContinuation<Value, Never>?
    }
    private let s = Mutex(S())

    func resolve(_ v: Value) {
        let waiter: CheckedContinuation<Value, Never>? = s.withLock { state in
            guard state.value == nil else { return nil }
            state.value = v
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: v)
    }

    func wait() async -> Value {
        await withCheckedContinuation { c in
            let ready: Value? = s.withLock {
                if let v = $0.value { return v }
                $0.waiter = c
                return nil
            }
            if let ready { c.resume(returning: ready) }
        }
    }

    /// Asks, but stops waiting after `timeout` (the card's late answer is ignored).
    static func ask(_ confirm: @escaping @Sendable (ActionProposal) async -> Bool, _ proposal: ActionProposal,
                    timeout: Duration) async -> Value {
        let answer = CardAnswer()
        let asker = Task { answer.resolve(await confirm(proposal) ? .accepted : .declined) }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            answer.resolve(.expired)
        }
        let value = await withTaskCancellationHandler {
            await answer.wait()
        } onCancel: {
            answer.resolve(.declined)
        }
        asker.cancel()
        timer.cancel()
        return value
    }
}

/// A failure the model can act on; `message` is the tool error text.
struct ToolFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// What an action will do, built before asking the user.
struct ActionPlan: Sendable {
    var summary: String
    var risk: ActionRisk
    /// Runs the action (under `PerformContext.generation`, at `PerformContext.now`).
    var perform: @Sendable (PerformContext) async throws -> ActionOutcome
}

struct ActionOutcome: Sendable {
    var fields: [String: LLM.JSONValue]
    /// The receipt line stored with the turn.
    var receipt: String
    var undo: UndoToken?
    var change: ActionChange
}

protocol ActionTool: ChatTool {
    var deps: ActionDeps { get }
    var risk: ActionRisk { get }
    /// Validates the arguments (throwing `ToolFailure`) and reads what the proposal needs.
    func plan(_ args: Args, context: ToolContext) async throws -> ActionPlan
}

extension ActionTool {
    var kind: ToolKind { .action(risk) }

    func run(arguments: String, context: ToolContext) async -> ToolRun {
        let name = definition.name
        let generation: Int
        let plan: ActionPlan
        do {
            generation = try context.generation ?? DataGeneration.current(deps.db)
            plan = try await self.plan(try Args(arguments), context: context)
        } catch {
            return Self.failure(name, error)
        }
        let ask = ActionPolicy.needsConfirmation(plan.risk, turnTainted: context.turnTainted)
        if ask {
            let proposal = ActionProposal(tool: name, summary: plan.summary, risk: plan.risk,
                                          afterUntrustedRead: context.turnTainted)
            let shown = deps.now()
            var answer = await CardAnswer.ask(context.confirm, proposal, timeout: deps.confirmTimeout)
            if answer == .accepted, deps.now().timeIntervalSince(shown) > ActionTools.confirmationLifetime { answer = .expired }
            switch answer {
            case .accepted: break
            case .declined:
                ActionTools.log.info("action \(name, privacy: .public) declined")
                return ToolRun(output: JSONOut.render(["status": .string("declined_by_user")]), isError: false,
                               confirmed: false)
            case .expired:
                ActionTools.log.info("action \(name, privacy: .public) confirmation expired")
                return ToolRun(output: JSONOut.render(["status": .string("confirmation_expired")]), isError: false,
                               confirmed: false)
            }
        }
        do {
            let outcome = try await plan.perform(PerformContext(generation: generation, now: deps.now(), confirmed: ask))
            await deps.effects.didChange(outcome.change)
            ActionTools.log.info("action \(name, privacy: .public) done")
            var fields = outcome.fields
            fields["status"] = .string("done")
            fields["undoable"] = .bool(outcome.undo != nil)
            return ToolRun(output: JSONOut.render(fields), isError: false,
                           receipt: ActionReceipt(summary: outcome.receipt, undo: outcome.undo, generation: generation),
                           confirmed: ask ? true : nil)
        } catch {
            return Self.failure(name, error)
        }
    }

    static func failure(_ name: String, _ error: any Error) -> ToolRun {
        let message: String
        switch error {
        case let e as ToolFailure: message = e.message
        case let e as ReminderError: message = ReminderText.fix(e)
        case let e as RecurrenceError: message = ReminderText.fix(e)
        case let e as SettingValueError: message = e.errorDescription ?? "Invalid value."
        case is DataGeneration.Stale:
            message = "The user deleted Remora's data during this conversation, so nothing was changed. Do not retry."
        default:
            ActionTools.log.error("action \(name, privacy: .public) failed")
            return .error("The action failed and nothing was changed.")
        }
        ActionTools.log.info("action \(name, privacy: .public) refused")
        return .error(message)
    }
}

/// Tool arguments. Schemas are strict (every field present); `""`, `0` and `[]` mean "not given".
struct Args {
    let raw: [String: MCP.Value]

    init(_ json: String) throws {
        do { raw = try ValueBridge.arguments(json) } catch { throw ToolFailure("Invalid arguments: expected a JSON object.") }
    }

    func string(_ key: String) throws -> String {
        switch raw[key] {
        case nil, .null?: return ""
        case .string(let s)?: return s.trimmingCharacters(in: .whitespacesAndNewlines)
        default: throw ToolFailure("\(key) must be a string.")
        }
    }

    func int(_ key: String) throws -> Int {
        switch raw[key] {
        case nil, .null?: return 0
        case .int(let i)?: return i
        case .double(let d)? where d == d.rounded() && abs(d) < 1e15: return Int(d)
        default: throw ToolFailure("\(key) must be an integer.")
        }
    }

    func strings(_ key: String) throws -> [String] {
        switch raw[key] {
        case nil, .null?: return []
        case .array(let a)?:
            return try a.map {
                guard case .string(let s) = $0 else { throw ToolFailure("\(key) must be an array of strings.") }
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
        default: throw ToolFailure("\(key) must be an array of strings.")
        }
    }

    func ids(_ key: String) throws -> [Int64] {
        switch raw[key] {
        case nil, .null?: return []
        case .array(let a)?:
            var out: [Int64] = []
            for v in a {
                let n: Int
                switch v {
                case .int(let i): n = i
                case .double(let d) where d == d.rounded() && abs(d) < 1e15: n = Int(d)
                default: throw ToolFailure("\(key) must be an array of integer ids.")
                }
                guard n > 0 else { throw ToolFailure("\(key) must hold positive ids.") }
                if !out.contains(Int64(n)) { out.append(Int64(n)) }
            }
            return out
        default: throw ToolFailure("\(key) must be an array of integer ids.")
        }
    }
}

enum JSONOut {
    static func render(_ fields: [String: LLM.JSONValue]) -> String { TimeReportTool.render(.object(fields)) }

    /// A strict schema: every property required, nothing else allowed.
    static func schema(_ properties: KeyValuePairs<String, LLM.JSONValue>) -> LLM.JSONValue {
        var props: [String: LLM.JSONValue] = [:]
        for (k, v) in properties { props[k] = v }
        return .object([
            "type": .string("object"),
            "properties": .object(props),
            "required": .array(properties.map { .string($0.key) }),
            "additionalProperties": .bool(false),
        ])
    }

    static func string(_ description: String, enum values: [String]? = nil) -> LLM.JSONValue {
        var o: [String: LLM.JSONValue] = ["type": .string("string"), "description": .string(description)]
        if let values { o["enum"] = .array(values.map(LLM.JSONValue.string)) }
        return .object(o)
    }

    static func integer(_ description: String) -> LLM.JSONValue {
        .object(["type": .string("integer"), "description": .string(description)])
    }

    static func array(_ itemType: String, _ description: String) -> LLM.JSONValue {
        .object(["type": .string("array"), "items": .object(["type": .string(itemType)]), "description": .string(description)])
    }
}

/// Local wall-clock times as the model reads and writes them: `yyyy-MM-dd'T'HH:mm`.
enum LocalTime {
    static let format = "yyyy-MM-dd'T'HH:mm"

    private static func formatter(_ calendar: Calendar, _ pattern: String = format) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = pattern
        f.isLenient = false
        return f
    }

    static func string(_ date: Date, _ calendar: Calendar) -> String { formatter(calendar).string(from: date) }

    static func parse(_ s: String, _ calendar: Calendar) -> Date? { formatter(calendar).date(from: s) }

    static func day(_ date: Date, _ calendar: Calendar) -> String { formatter(calendar, "yyyy-MM-dd").string(from: date) }

    static func clock(_ date: Date, _ calendar: Calendar) -> String { formatter(calendar, "HH:mm").string(from: date) }
}

/// Quotes model-written text in a proposal or receipt, in full (the card must show everything
/// that will be stored; each tool caps its text length instead).
func quoted(_ s: String) -> String {
    "“" + s + "”"
}

/// A stored title (derived from captured text) as a card or receipt shows it: at most
/// `maxTitleChars`, cut with "…".
let maxTitleChars = 200
func shortTitle(_ s: String) -> String {
    s.count <= maxTitleChars ? s : String(s.prefix(maxTitleChars - 1)) + "…"
}

// MARK: - Reminders

enum ReminderText {
    static let rruleHelp = """
        Supported RRULE parts: FREQ=DAILY, WEEKLY or MONTHLY; INTERVAL; BYDAY (weekly only, no ordinals, e.g. \
        BYDAY=MO,WE); BYMONTHDAY (monthly only, 1 to 31 or -1 for the last day); BYHOUR; BYMINUTE; COUNT or UNTIL. \
        For a yearly date, create a one-off reminder instead.
        """

    static func fix(_ e: RecurrenceError) -> String {
        switch e {
        case .unsupported(let part): "Unsupported RRULE part \(part). " + rruleHelp
        case .invalid(let part): "Invalid RRULE part \(part). " + rruleHelp
        }
    }

    static func fix(_ e: ReminderError) -> String {
        switch e {
        case .inPast: "That time is in the past. Give a future local time as yyyy-MM-dd'T'HH:mm."
        case .tooFar: "A reminder can be at most \(ReminderEngine.maxAheadYears) years ahead."
        case .intervalTooShort(let m): "every_minutes must be at least \(m) for this action."
        case .tooMany: "There are already \(ReminderEngine.maxActive) active reminders. Ask the user which one to cancel first."
        case .emptyText: "text must not be empty."
        case .notFound: "No such reminder. Call list_reminders for the ids."
        case .noFutureOccurrence: "This rule has no future occurrence. Check COUNT, UNTIL and the start time."
        }
    }

    /// "Once on 2026-11-21 at 09:30", "Every 90 minutes", "Every Friday at 17:00".
    static func describe(_ r: Reminder, calendar: Calendar) -> String {
        switch r.kind {
        case .once: return once(r.anchorAt, calendar)
        case .interval: return every(seconds: r.intervalSeconds ?? 0)
        case .recurring:
            guard let s = r.rrule, let rule = try? RecurrenceRule.parse(s, calendar: calendar) else { return "Recurring" }
            return rule.describe(calendar: calendar, locale: Locale(identifier: "en_US_POSIX"))
        }
    }

    static func once(_ date: Date, _ calendar: Calendar) -> String {
        "Once on \(LocalTime.day(date, calendar)) at \(LocalTime.clock(date, calendar))"
    }

    static func every(seconds: Int) -> String {
        if seconds > 0, seconds % 3_600 == 0 {
            let h = seconds / 3_600
            return h == 1 ? "Every hour" : "Every \(h) hours"
        }
        let m = seconds / 60
        return m == 1 ? "Every minute" : "Every \(m) minutes"
    }
}

struct CreateReminderTool: ActionTool {
    let deps: ActionDeps
    var risk: ActionRisk { .reversible }

    var definition: FunctionTool {
        FunctionTool(
            name: "create_reminder",
            description: """
                Create a reminder the user asked for. action notify shows the text at the time; prompt runs the text \
                as a request to you (read-only) and delivers your answer. kind once fires at `at`; recurring follows \
                `rrule` (RFC 5545 subset) starting at `at` (its time of day is used when the rule has no BYHOUR); \
                interval fires every `every_minutes` from `at`. Times are the user's local time as \
                yyyy-MM-dd'T'HH:mm. Unused fields: "" or 0.
                """,
            parameters: JSONOut.schema([
                "text": JSONOut.string("What to remind about (or the prompt to run), in the user's words"),
                "action": JSONOut.string("notify or prompt", enum: ["notify", "prompt"]),
                "kind": JSONOut.string("once, recurring or interval", enum: ["once", "recurring", "interval"]),
                "at": JSONOut.string("Local yyyy-MM-dd'T'HH:mm; required for once; \"\" = now for recurring/interval"),
                "rrule": JSONOut.string("RRULE body for recurring, e.g. FREQ=WEEKLY;BYDAY=FR; \"\" otherwise"),
                "every_minutes": JSONOut.integer("Period for interval (at least 5 for notify, 60 for prompt); 0 otherwise"),
            ]))
    }

    func plan(_ args: Args, context: ToolContext) async throws -> ActionPlan {
        let text = try args.string("text")
        guard !text.isEmpty else { throw ToolFailure("text must not be empty.") }
        guard text.count <= 1_000 else { throw ToolFailure("text is too long (at most 1000 characters).") }
        guard let action = ReminderAction(rawValue: try args.string("action")) else {
            throw ToolFailure("action must be notify or prompt.")
        }
        guard let kind = ReminderKind(rawValue: try args.string("kind")) else {
            throw ToolFailure("kind must be once, recurring or interval.")
        }
        let cal = context.calendar
        let atText = try args.string("at")
        var at: Date?
        if !atText.isEmpty {
            guard let d = LocalTime.parse(atText, cal) else {
                throw ToolFailure("at must be a local time written yyyy-MM-dd'T'HH:mm, e.g. 2026-11-21T09:30.")
            }
            at = d
        }
        let schedule: ReminderSchedule
        let described: String
        switch kind {
        case .once:
            guard let at else { throw ToolFailure("A once reminder needs at (local yyyy-MM-dd'T'HH:mm).") }
            guard at > context.now else { throw ReminderError.inPast }
            schedule = .once(at)
            described = ReminderText.once(at, cal)
        case .recurring:
            let body = try args.string("rrule")
            guard !body.isEmpty else { throw ToolFailure("A recurring reminder needs rrule. " + ReminderText.rruleHelp) }
            let rule = try RecurrenceRule.parse(body, calendar: cal)
            let anchor = at ?? context.now
            schedule = .recurring(rule, anchor: anchor)
            described = ReminderEngine.stamped(rule, anchor: anchor, calendar: cal)
                .describe(calendar: cal, locale: Locale(identifier: "en_US_POSIX"))
        case .interval:
            let minutes = try args.int("every_minutes")
            let minimum = action == .prompt ? 60 : 5
            guard minutes >= minimum else { throw ReminderError.intervalTooShort(minimumMinutes: minimum) }
            guard minutes <= 525_600 else { throw ToolFailure("every_minutes is too large (at most one year).") }
            schedule = .interval(seconds: minutes * 60, anchor: at ?? context.now)
            described = ReminderText.every(seconds: minutes * 60)
        }
        let what = action == .prompt ? "Run the request \(quoted(text))" : "Remind you \(quoted(text))"
        let deps = deps
        return ActionPlan(summary: "\(what): \(described)", risk: risk) { p in
            let r = try await deps.reminders.create(ReminderDraft(text: text, action: action, schedule: schedule,
                                                                   origin: .chat), expected: p.generation)
            guard let id = r.id else { throw ToolFailure("The reminder could not be saved.") }
            let stored = ReminderText.describe(r, calendar: cal)
            return ActionOutcome(
                fields: [
                    "id": .number(Double(id)),
                    "next_fire_at": r.nextFireAt.map { .string(LocalTime.string($0, cal)) } ?? .null,
                    "schedule": .string(stored),
                ],
                receipt: "Reminder \(quoted(text)): \(stored)", undo: .cancelReminder(id), change: .reminders)
        }
    }
}

/// `list_reminders`: the active reminders.
struct ListRemindersTool: ChatTool {
    let deps: ActionDeps
    /// Reminder texts may have been written by the model (from captured text): untrusted.
    var kind: ToolKind { .untrustedRead }

    var definition: FunctionTool {
        FunctionTool(
            name: "list_reminders",
            description: "The user's active reminders, soonest first, with their ids (for cancel_reminder).",
            parameters: JSONOut.schema([:]))
    }

    func run(arguments: String, context: ToolContext) async -> ToolRun {
        do {
            let cal = context.calendar
            let rows = try await deps.reminders.list()
            let out: [LLM.JSONValue] = rows.compactMap { r in
                guard let id = r.id else { return nil }
                return .object([
                    "id": .number(Double(id)), "text": .string(r.text), "action": .string(r.action.rawValue),
                    "kind": .string(r.kind.rawValue), "schedule": .string(ReminderText.describe(r, calendar: cal)),
                    "next_fire_at": r.nextFireAt.map { .string(LocalTime.string($0, cal)) } ?? .null,
                ])
            }
            return ToolRun(output: JSONOut.render(["reminders": .array(out), "count": .number(Double(out.count))]),
                           isError: false)
        } catch {
            ActionTools.log.error("list_reminders failed")
            return .error("Could not read the reminders.")
        }
    }
}

struct CancelReminderTool: ActionTool {
    let deps: ActionDeps
    var risk: ActionRisk { .reversible }

    var definition: FunctionTool {
        FunctionTool(
            name: "cancel_reminder",
            description: "Cancel one of the user's active reminders, by its id from list_reminders.",
            parameters: JSONOut.schema(["id": JSONOut.integer("The reminder id")]))
    }

    func plan(_ args: Args, context: ToolContext) async throws -> ActionPlan {
        let id = Int64(try args.int("id"))
        let notActive = ToolFailure("No active reminder has id \(id). Call list_reminders for the ids.")
        guard id > 0, let r = try ReminderStore(deps.db).get(id), r.status == .active else { throw notActive }
        let deps = deps
        let described = ReminderText.describe(r, calendar: context.calendar)
        return ActionPlan(summary: "Cancel the reminder \(quoted(r.text)) (\(described))", risk: risk) { p in
            guard let done = try await deps.reminders.cancelIfActive(id, expected: p.generation) else { throw notActive }
            return ActionOutcome(fields: ["id": .number(Double(id))], receipt: "Cancelled the reminder \(quoted(done.text))",
                                 undo: .reactivateReminder(id), change: .reminders)
        }
    }
}

// MARK: - Privacy

struct AddExclusionTool: ActionTool {
    let deps: ActionDeps
    var risk: ActionRisk { .reversible }

    static let maxPatternChars = 200

    static let syntax = """
        Use a site (example.com), app:Name (an app), title:text (window titles containing text), url:text (page \
        addresses containing text) or path:text (file paths containing text).
        """

    var definition: FunctionTool {
        FunctionTool(
            name: "add_exclusion",
            description: """
                Stop capturing an app, site, window title, address or file path, when the user asks. Excluded \
                captures are also hidden from memory. \(Self.syntax) Exclusions can only be added here; the user \
                removes them in Settings › Privacy.
                """,
            parameters: JSONOut.schema(["pattern": JSONOut.string("The exclusion pattern")]))
    }

    func plan(_ args: Args, context: ToolContext) async throws -> ActionPlan {
        let raw = try args.string("pattern")
        guard raw.count <= Self.maxPatternChars else {
            throw ToolFailure("The exclusion pattern is too long (at most \(Self.maxPatternChars) characters). Use a shorter part of it.")
        }
        guard let rule = ExclusionRule(pattern: raw) else {
            throw ToolFailure("Invalid exclusion pattern. " + Self.syntax)
        }
        let pattern = rule.pattern
        let summary = switch rule {
        case .domain(let d): "Never capture the site \(d)"
        case .app(let a): "Never capture the app \(a)"
        case .title(let t): "Never capture windows whose title contains \(quoted(t))"
        case .url(let u): "Never capture pages whose address contains \(quoted(u))"
        case .path(let p): "Never capture files whose path contains \(quoted(p))"
        }
        let deps = deps
        return ActionPlan(summary: summary, risk: risk) { p in
            let added = try DataGeneration.write(deps.db, expected: p.generation) { d in
                try ExclusionStore.add(pattern, at: p.now, in: d)
            }
            // Undo removes only an exclusion this action created, never one the user had.
            return ActionOutcome(fields: ["pattern": .string(pattern), "already_excluded": .bool(!added)],
                                 receipt: summary, undo: added ? .removeExclusion(pattern) : nil, change: .exclusions)
        }
    }
}

struct PauseCaptureTool: ActionTool {
    let deps: ActionDeps
    /// Pausing (longer) is reversible; resuming or shortening an active pause captures more, so
    /// the plan asks (`confirm`) in that case.
    var risk: ActionRisk { .reversible }

    var definition: FunctionTool {
        FunctionTool(
            name: "pause_capture",
            description: """
                Pause screen capture for 15 minutes, 1 hour, until tomorrow 08:00 or until resumed, or resume it now. \
                Resuming or shortening a pause asks the user first.
                """,
            parameters: JSONOut.schema([
                "duration": JSONOut.string("How long", enum: ["15m", "1h", "until_tomorrow", "indefinitely", "resume"]),
            ]))
    }

    func plan(_ args: Args, context: ToolContext) async throws -> ActionPlan {
        let duration: PauseDuration?
        switch try args.string("duration") {
        case "15m": duration = .minutes15
        case "1h": duration = .hour1
        case "until_tomorrow": duration = .untilTomorrow
        case "indefinitely": duration = .indefinitely
        case "resume": duration = nil
        default: throw ToolFailure("duration must be 15m, 1h, until_tomorrow, indefinitely or resume.")
        }
        let cal = context.calendar
        let current: Date?
        do { current = try SettingsStore(deps.db).pausedUntil() } catch {
            throw ToolFailure("Remora could not read the pause state; the user can pause or resume from the menu bar.")
        }
        /// Resuming, or ending an active pause sooner, captures more.
        @Sendable func shortens(_ current: Date?, at now: Date) -> Bool {
            let end = duration?.end(from: now, calendar: cal)
            return current.map { $0 > now && (end ?? now) < $0 } ?? false
        }
        let planned = shortens(current, at: context.now)
        let summary = switch duration {
        case nil: "Resume capture now"
        case .indefinitely?: "Pause capture until you resume it"
        case .untilTomorrow?: "Pause capture until tomorrow at 08:00"
        case .hour1?: "Pause capture for 1 hour"
        case .minutes15?: "Pause capture for 15 minutes"
        }
        let deps = deps
        return ActionPlan(summary: summary, risk: planned ? .confirm : .reversible) { p in
            // The end and the shortening test use the time the action runs, not when the card was built.
            let settings = SettingsStore(deps.db)
            let end = duration?.end(from: p.now, calendar: cal)
            let (previous, applied) = try DataGeneration.write(deps.db, expected: p.generation) { d in
                let previous = try settings.pausedUntil(in: d)
                if shortens(previous, at: p.now), !planned {
                    throw ToolFailure("""
                        The pause changed while waiting, and this would now end it sooner. Nothing was changed; \
                        ask the user again.
                        """)
                }
                try settings.pause(until: end, in: d)
                return (previous, try settings.pausedUntil(in: d))
            }
            let until: LLM.JSONValue = switch end {
            case nil: .null
            case .distantFuture?: .string("until resumed")
            case let e?: .string(LocalTime.string(e, cal))
            }
            return ActionOutcome(fields: ["paused_until": until, "capturing": .bool(end == nil)],
                                 receipt: summary, undo: .restorePause(previous: previous, applied: applied), change: .pause)
        }
    }
}

// MARK: - Memory

struct UpdateIdentityTool: ActionTool {
    let deps: ActionDeps
    var risk: ActionRisk { .confirm }
    static let maxLines = 20
    static let maxLineChars = 300

    var definition: FunctionTool {
        FunctionTool(
            name: "update_identity",
            description: """
                Edit the user's identity profile (who they are, how they work) when they ask: lines are added at the \
                end, and lines are removed by a case- and spacing-insensitive match. The user always confirms. \
                Saved as the user's own edit, which Remora's background updates keep.
                """,
            parameters: JSONOut.schema([
                "add_lines": JSONOut.array("string", "Lines to add, each one short statement; [] for none"),
                "remove_lines": JSONOut.array("string", "Existing lines to remove; [] for none"),
            ]))
    }

    /// Lines compare without case, list markers or extra spaces.
    static func key(_ line: some StringProtocol) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "• "] where s.hasPrefix(marker) { s.removeFirst(marker.count); break }
        return s.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    func plan(_ args: Args, context: ToolContext) async throws -> ActionPlan {
        let redactor = Redactor()
        let add = try args.strings("add_lines").map { redactor.redact($0.split(whereSeparator: \.isNewline).joined(separator: " ")) }
        let remove = try args.strings("remove_lines")
        guard !add.isEmpty || !remove.isEmpty else { throw ToolFailure("Give add_lines or remove_lines.") }
        guard add.count <= Self.maxLines, remove.count <= Self.maxLines else {
            throw ToolFailure("At most \(Self.maxLines) lines to add and \(Self.maxLines) to remove.")
        }
        guard (add + remove).allSatisfy({ $0.count <= Self.maxLineChars }) else {
            throw ToolFailure("Each line must be at most \(Self.maxLineChars) characters.")
        }
        var parts: [String] = []
        if !add.isEmpty { parts.append("add " + add.map { quoted($0) }.joined(separator: ", ")) }
        if !remove.isEmpty { parts.append("remove " + remove.map { quoted($0) }.joined(separator: ", ")) }
        let summary = "Update your identity: " + parts.joined(separator: "; ")
        let deps = deps
        return ActionPlan(summary: summary, risk: risk) { p in
            let (added, removed, missing) = try DataGeneration.write(deps.db, expected: p.generation) { d in
                let body = try IdentityStore.current(in: d)?.body ?? ""
                var lines = body.isEmpty ? [] : body.components(separatedBy: "\n")
                let removeKeys = Set(remove.map { Self.key($0) })
                var matched = Set<String>()
                lines.removeAll { line in
                    let k = Self.key(line)
                    guard !k.isEmpty, removeKeys.contains(k) else { return false }
                    matched.insert(k)
                    return true
                }
                // Match the profile's bullet style.
                let content = lines.filter { !Self.key($0).isEmpty }
                let bulleted = !content.isEmpty && content.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }
                var keys = Set(lines.map { Self.key($0) })
                var added = 0
                for line in add where !keys.contains(Self.key(line)) {
                    keys.insert(Self.key(line))
                    lines.append(bulleted && !line.hasPrefix("- ") ? "- " + line : line)
                    added += 1
                }
                try IdentityStore.saveUserEdit(lines.joined(separator: "\n"), at: p.now, in: d)
                return (added, matched.count, remove.filter { !matched.contains(Self.key($0)) })
            }
            return ActionOutcome(
                fields: ["added": .number(Double(added)), "removed": .number(Double(removed)),
                         "not_found": .array(missing.map(LLM.JSONValue.string))],
                receipt: "Identity updated (\(added) added, \(removed) removed)", undo: nil, change: .identity)
        }
    }
}

struct CorrectWikiTool: ActionTool {
    let deps: ActionDeps
    var risk: ActionRisk { .confirm }
    static let maxChars = 300

    var definition: FunctionTool {
        FunctionTool(
            name: "correct_wiki",
            description: """
                Record a correction the user states about a wiki page (slug from search_wiki or list_wiki), as a fact \
                the user stated. invalidate_fact_ids lists the page's current fact ids (from get_wiki_page) that the \
                correction makes untrue; [] for none. The user always confirms.
                """,
            parameters: JSONOut.schema([
                "slug": JSONOut.string("The page slug"),
                "correction": JSONOut.string("The correct fact, one short sentence"),
                "invalidate_fact_ids": JSONOut.array("integer", "Fact ids of this page that are no longer true"),
            ]))
    }

    func plan(_ args: Args, context: ToolContext) async throws -> ActionPlan {
        let slug = try args.string("slug")
        let correction = Redactor().redact(try args.string("correction").split(whereSeparator: \.isNewline).joined(separator: " "))
        let ids = try args.ids("invalidate_fact_ids")
        guard !correction.isEmpty else { throw ToolFailure("correction must not be empty.") }
        guard correction.count <= Self.maxChars else { throw ToolFailure("correction must be at most \(Self.maxChars) characters.") }
        let store = WikiStore(deps.db)
        guard let page = try store.page(slug: slug) else {
            throw ToolFailure("No wiki page has slug \(slug). Find it with search_wiki or list_wiki.")
        }
        var valid: [Int64: WikiFact] = [:]
        for f in try store.validFacts(slug: slug) { if let id = f.id { valid[id] = f } }
        if let bad = ids.first(where: { valid[$0] == nil }) {
            throw ToolFailure("Fact \(bad) is not a current fact of this page. Use the ids get_wiki_page shows.")
        }
        var summary = "Correct the wiki page \(quoted(shortTitle(page.title))): \(quoted(correction))"
        if !ids.isEmpty {
            summary += ", and mark \(ids.count == 1 ? "this fact" : "these facts") as no longer true:\n"
                + ids.compactMap { valid[$0] }.map { "- " + quoted($0.fact) }.joined(separator: "\n")
        }
        let deps = deps
        return ActionPlan(summary: summary, risk: risk) { p in
            let fact: WikiFact
            do {
                fact = try DataGeneration.write(deps.db, expected: p.generation) { d in
                    try WikiStore.addUserFact(slug: slug, text: correction, invalidating: ids, at: p.now, in: d)
                }
            } catch is WikiStore.NotFound {
                throw ToolFailure("The wiki page no longer exists; nothing was changed.")
            } catch let e as WikiStore.InvalidFact {
                throw ToolFailure("Fact \(e.id) is no longer a current fact of this page; nothing was changed.")
            }
            return ActionOutcome(
                fields: ["fact_id": fact.id.map { .number(Double($0)) } ?? .null,
                         "invalidated": .array(ids.map { .number(Double($0)) })],
                receipt: "Wiki page \(quoted(shortTitle(page.title))) corrected", undo: nil, change: .wiki)
        }
    }
}

struct ForgetSnapshotsTool: ActionTool {
    let deps: ActionDeps
    var risk: ActionRisk { .confirm }
    static let maxIDs = 20
    static let identityNote = "Check Settings › Identity if it mentions this."
    static let chatNote = "Earlier chat messages won't be reused; Clear chat removes them from view."

    var definition: FunctionTool {
        FunctionTool(
            name: "forget_snapshots",
            description: """
                Permanently delete captures (snapshot ids from search_memory or get_snapshots) and everything \
                Remora learned only from them, when the user asks to forget something. 1 to 20 ids. Cannot be \
                undone; the user always confirms. The identity profile is not edited automatically.
                """,
            parameters: JSONOut.schema(["ids": JSONOut.array("integer", "Snapshot ids, 1 to 20")]))
    }

    func plan(_ args: Args, context: ToolContext) async throws -> ActionPlan {
        let ids = try args.ids("ids")
        guard (1...Self.maxIDs).contains(ids.count) else { throw ToolFailure("ids must hold 1 to \(Self.maxIDs) snapshot ids.") }
        // The card lists each capture (local only: the summary is shown on the card, never sent).
        let found = try SnapshotStore(deps.db).snapshots(ids: ids)
        let known = Set(found.compactMap(\.id))
        let missing = ids.filter { !known.contains($0) }
        guard missing.isEmpty else {
            throw ToolFailure("No capture has id " + missing.map(String.init).joined(separator: ", ")
                              + ". Use the ids search_memory or get_snapshots returned.")
        }
        let cal = context.calendar
        let lines = found.sorted { ($0.capturedAt, $0.id ?? 0) < ($1.capturedAt, $1.id ?? 0) }.map { s in
            var parts = [s.app]
            if let title = s.windowTitle, !title.isEmpty { parts.append(quoted(title)) }
            parts.append(LocalTime.day(s.capturedAt, cal) + " " + LocalTime.clock(s.capturedAt, cal))
            return "- " + parts.joined(separator: ", ")
        }
        let n = ids.count
        let summary = "Forget \(n) capture\(n == 1 ? "" : "s") and anything Remora learned only from \(n == 1 ? "it" : "them"). This cannot be undone.\n"
            + lines.joined(separator: "\n")
        let deps = deps
        return ActionPlan(summary: summary, risk: risk) { p in
            // Checked but not bumped: running jobs drop forgotten ids themselves (Plan 4 F-61).
            let report = try DataGeneration.write(deps.db, expected: p.generation) { d in
                try SnapshotStore.delete(ids: ids, now: p.now, in: d)
            }
            let forgotten = report.deleted["snapshots"] ?? 0
            var derived = report.deleted
            derived["snapshots"] = nil
            return ActionOutcome(
                fields: ["forgotten": .number(Double(forgotten)),
                         "derived_deleted": .object(derived.mapValues { .number(Double($0)) }),
                         "derived_updated": .object(report.dirtied.mapValues { .number(Double($0)) }),
                         "note": .string(Self.identityNote + " " + Self.chatNote)],
                receipt: "Forgot \(forgotten) capture\(forgotten == 1 ? "" : "s"). \(Self.identityNote) \(Self.chatNote)",
                undo: nil, change: .snapshots)
        }
    }
}

// MARK: - Settings

struct UpdateSettingTool: ActionTool {
    let deps: ActionDeps
    /// The entry's risk decides; this is the default.
    var risk: ActionRisk { .reversible }

    /// A shorter raw-capture retention purges captures, which no undo brings back.
    static func shortensRetention(name: String, from: String, to: String) -> Bool {
        guard name == "raw_capture_retention" else { return false }
        func days(_ v: String) -> Int { v == "forever" ? .max : Int(v) ?? .max }
        return days(to) < days(from)
    }

    var definition: FunctionTool {
        let lines = SettingRegistry.entries.map { "\($0.name): \($0.values)" }.joined(separator: "; ")
        return FunctionTool(
            name: "update_setting",
            description: """
                Change one of these Remora settings when the user asks (\(lines)). Returns the previous and new \
                value. Background memory and capture retention ask the user first. Other settings (account, \
                exclusions, MCP, deleting data) can only be changed by the user in Settings.
                """,
            parameters: JSONOut.schema([
                "name": JSONOut.string("The setting", enum: SettingRegistry.entries.map(\.name)),
                "value": JSONOut.string("The new value, as listed"),
            ]))
    }

    func plan(_ args: Args, context: ToolContext) async throws -> ActionPlan {
        let name = try args.string("name")
        guard let entry = SettingRegistry.entry(name) else {
            throw ToolFailure("Unknown setting. Allowed: " + SettingRegistry.entries.map(\.name).joined(separator: ", ") + ".")
        }
        let value = try entry.validate(try args.string("value"))
        let settings = SettingsStore(deps.db)
        let shown = try await deps.db.reader.read { d in try entry.get(settings, d) }
        var summary = "Change the setting \(name) from \(shown) to \(value)"
        if Self.shortensRetention(name: name, from: shown, to: value) {
            summary += ". Captures older than \(value) days will be deleted, and undo can't bring them back"
        }
        let deps = deps
        return ActionPlan(summary: summary, risk: entry.risk) { p in
            let (previous, applied) = try DataGeneration.write(deps.db, expected: p.generation) { d in
                let previous = try entry.get(settings, d)
                if previous != value { try entry.set(settings, d, value) }
                return (previous, try entry.get(settings, d))
            }
            let changed = previous != value
            var receipt = "Changed \(name) from \(previous) to \(value)"
            if changed, Self.shortensRetention(name: name, from: previous, to: value) {
                receipt += ". Undo restores the setting, but captures purged in the meantime can't be restored"
            }
            return ActionOutcome(
                fields: ["name": .string(name), "previous": .string(previous), "value": .string(value),
                         "changed": .bool(changed)],
                receipt: receipt,
                undo: changed ? .restoreSetting(name: name, previous: previous, applied: applied) : nil,
                change: .setting(name))
        }
    }
}
