import Foundation
import Storage
import os

public struct LLMResult: Sendable, Equatable {
    public var text: String
    public var functionCalls: [FunctionCall]
    public var callID: Int64
    public var route: Route
    public var usage: LLMUsage
    public init(text: String, functionCalls: [FunctionCall], callID: Int64, route: Route, usage: LLMUsage) {
        self.text = text; self.functionCalls = functionCalls; self.callID = callID; self.route = route; self.usage = usage
    }
}

/// Routes a job to a backend and writes one `llm_calls` row per attempt (content is never stored).
///
/// Text is returned only after the response completed; a partial result is never used. At most one
/// automatic retry per `complete()` call (not per route) for a retryable error, and none once output
/// was delivered through `onDelta`.
///
/// `onDelta` deltas are provisional: the stream may still fail, be retried or fall back after they
/// were delivered. Use them only as a progress hint; the result is `LLMResult.text` of a successful
/// call.
public actor LLMService {
    public static let lastLimitKey = "llm.lastLimitAt"

    private let siwc: any LLMClient
    private let onDevice: any LLMClient
    private let onDeviceAvailability: @Sendable () -> OnDeviceAvailability
    private let calls: LLMCallStore
    private let routing: @Sendable () -> RoutingConfig
    private let catalog: @Sendable () -> [ModelInfo]
    private let prices: @Sendable () -> PriceTable
    private let now: @Sendable () -> Date
    private let settings: SettingsStore?
    private let retryDelay: Duration
    private var limitAt: Date?

    private static let log = Logger(subsystem: "dev.remora", category: "llm")

    public init(siwc: any LLMClient, onDevice: any LLMClient,
                onDeviceAvailability: @escaping @Sendable () -> OnDeviceAvailability,
                calls: LLMCallStore,
                routing: @escaping @Sendable () -> RoutingConfig,
                catalog: @escaping @Sendable () -> [ModelInfo],
                prices: @escaping @Sendable () -> PriceTable,
                now: @escaping @Sendable () -> Date = Date.init,
                settings: SettingsStore? = nil,
                retryDelay: Duration = .seconds(1)) {
        self.siwc = siwc; self.onDevice = onDevice; self.onDeviceAvailability = onDeviceAvailability
        self.calls = calls; self.routing = routing; self.catalog = catalog; self.prices = prices
        self.now = now; self.settings = settings; self.retryDelay = retryDelay
    }

    /// When a usage limit was last hit (kept in `llm.lastLimitAt` when a settings store is given).
    public func lastLimitAt() -> Date? {
        if let limitAt { return limitAt }
        return (try? settings?.value(Date.self, forKey: Self.lastLimitKey)) ?? nil
    }

    public func complete(_ job: JobType, instructions: String, input: [InputItem],
                         format: TextFormat = .text, tools: [FunctionTool] = [],
                         cloudAllowed: Bool = true,
                         onDelta: (@Sendable (String) -> Void)? = nil) async throws -> LLMResult {
        let config = routing(), availability = onDeviceAvailability()
        var routes = LLMRouter.routes(job: job, config: config, catalog: catalog(), onDevice: availability,
                                      cloudAllowed: cloudAllowed)
        if !tools.isEmpty { routes.removeAll { $0.backend == .onDevice } }
        var lastError = LLMError.configuration(code: "no_route")
        if routes.isEmpty, !cloudAllowed {
            // Fail closed, saying why the on-device model could not be used.
            let reason = switch availability {
            case .unavailable(let r) where config.onDeviceEnabled: r
            case _ where !config.onDeviceEnabled: "The on-device model is turned off in Settings."
            default: "The on-device model can't run this request."
            }
            throw LLMError.onDeviceUnavailable(reason: reason)
        }
        var retried = false
        for (index, route) in routes.enumerated() {
            let client = route.backend == .onDevice ? onDevice : siwc
            let request = LLMRequest(model: route.model, instructions: instructions, input: input,
                                     reasoning: route.effort, format: format, tools: tools)
            while true {
                if Task.isCancelled { throw LLMError.cancelled }
                let attempt = await attempt(job, route, client, request, onDelta)
                switch attempt.outcome {
                case .success(let result):
                    return result
                case .failure(let error):
                    if error.isRetryable, !attempt.delivered, !retried {
                        retried = true
                        do { try await Task.sleep(for: retryDelay) } catch { throw LLMError.cancelled }
                        continue
                    }
                    let canFall = route.backend == .onDevice && !attempt.delivered && index + 1 < routes.count
                    if canFall, error == .schemaMismatch || isOnDeviceUnavailable(error) {
                        lastError = error
                    } else {
                        throw error
                    }
                }
                break
            }
        }
        throw lastError
    }

    private func isOnDeviceUnavailable(_ e: LLMError) -> Bool {
        if case .onDeviceUnavailable = e { return true }
        return false
    }

    private struct Attempt {
        var outcome: Result<LLMResult, LLMError>
        var delivered: Bool
    }

    private func attempt(_ job: JobType, _ route: Route, _ client: any LLMClient, _ request: LLMRequest,
                         _ onDelta: (@Sendable (String) -> Void)?) async -> Attempt {
        let started = now()
        var text = ""
        var functionCalls: [FunctionCall] = []
        var usage: LLMUsage?
        var failure: LLMError?
        var delivered = false
        var liveText = false
        if case .text = request.format { liveText = true }

        do {
            for try await event in client.stream(request) {
                switch event {
                case .textDelta(let d):
                    text += d
                    if liveText, let onDelta { delivered = true; onDelta(d) }
                case .functionCall(let c): functionCalls.append(c)
                case .completed(let u): usage = u
                }
            }
        } catch {
            failure = LLMError.wrapping(error)
        }
        // The consumer's cancellation ends the stream silently: never treat that as a result.
        if Task.isCancelled { failure = .cancelled }
        if failure == nil, usage == nil { failure = .streamEndedEarly }
        if failure == nil, route.backend == .onDevice, case .jsonSchema(_, let schema, _) = request.format,
           !SchemaCheck.validate(text, against: schema) {
            failure = .schemaMismatch
        }

        let callID = record(job, route, started: started, usage: usage, failure: failure)
        if let failure {
            if failure == .usageLimit { noteLimit() }
            return Attempt(outcome: .failure(failure), delivered: delivered)
        }
        if !liveText, let onDelta, !text.isEmpty { delivered = true; onDelta(text) }
        let result = LLMResult(text: text, functionCalls: functionCalls, callID: callID, route: route, usage: usage ?? .zero)
        return Attempt(outcome: .success(result), delivered: delivered)
    }

    private func record(_ job: JobType, _ route: Route, started: Date, usage: LLMUsage?, failure: LLMError?) -> Int64 {
        let u = usage ?? .zero
        let finished = now()
        let row = LLMCall(
            startedAt: started, durationMs: max(0, Int(finished.timeIntervalSince(started) * 1000)),
            backend: route.backend.rawValue, model: route.model, reasoningEffort: route.effort?.rawValue,
            jobType: job.rawValue, status: failure?.callStatus ?? .completed, errorCode: failure?.errorCode,
            inputTokens: u.inputTokens, cachedInputTokens: u.cachedInputTokens,
            outputTokens: u.outputTokens, reasoningTokens: u.reasoningTokens,
            estCostUSD: usage.flatMap { prices().cost(model: route.model, usage: $0, backend: route.backend) })
        Self.log.info("call \(job.rawValue, privacy: .public) \(route.backend.rawValue, privacy: .public) \(route.model, privacy: .public) \(row.status.rawValue, privacy: .public) \(row.errorCode ?? "-", privacy: .public)")
        do { return try calls.insert(row).id ?? 0 } catch {
            Self.log.error("llm_calls write failed")
            return 0
        }
    }

    private func noteLimit() {
        let at = now()
        limitAt = at
        do { try settings?.setValue(at, forKey: Self.lastLimitKey) } catch { Self.log.error("could not store lastLimitAt") }
    }
}
