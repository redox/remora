import Foundation

/// Stored in the setting `llm.routing`.
public struct RoutingConfig: Codable, Sendable, Equatable {
    public static let settingKey = "llm.routing"

    /// The user's pick per tier; absent means automatic.
    public var tierModels: [Tier: String] = [:]
    /// Per-job tier overrides.
    public var jobTiers: [JobType: Tier] = [:]
    public var onDeviceEnabled = true

    public init(tierModels: [Tier: String] = [:], jobTiers: [JobType: Tier] = [:], onDeviceEnabled: Bool = true) {
        self.tierModels = tierModels; self.jobTiers = jobTiers; self.onDeviceEnabled = onDeviceEnabled
    }

    public func tier(for job: JobType) -> Tier { jobTiers[job] ?? job.defaultTier }

    private enum CodingKeys: String, CodingKey { case tierModels, jobTiers, onDeviceEnabled }

    /// Keys are written as plain strings; unknown tiers/jobs from a newer build are skipped.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        for (k, v) in try c.decodeIfPresent([String: String].self, forKey: .tierModels) ?? [:] {
            if let t = Tier(rawValue: k) { tierModels[t] = v }
        }
        for (k, v) in try c.decodeIfPresent([String: String].self, forKey: .jobTiers) ?? [:] {
            if let j = JobType(rawValue: k), let t = Tier(rawValue: v) { jobTiers[j] = t }
        }
        onDeviceEnabled = try c.decodeIfPresent(Bool.self, forKey: .onDeviceEnabled) ?? true
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Dictionary(uniqueKeysWithValues: tierModels.map { ($0.key.rawValue, $0.value) }), forKey: .tierModels)
        try c.encode(Dictionary(uniqueKeysWithValues: jobTiers.map { ($0.key.rawValue, $0.value.rawValue) }), forKey: .jobTiers)
        try c.encode(onDeviceEnabled, forKey: .onDeviceEnabled)
    }
}

public struct Route: Sendable, Equatable {
    public var backend: LLMBackend
    public var model: String
    public var effort: ReasoningEffort?
    public var tier: Tier
    public init(backend: LLMBackend, model: String, effort: ReasoningEffort?, tier: Tier) {
        self.backend = backend; self.model = model; self.effort = effort; self.tier = tier
    }
}

public enum LLMRouter {
    /// An ordered list of attempts. Only the on-device tier may fall back (to small); cloud tiers
    /// never silently downgrade. With `cloudAllowed == false` the only possible route is on-device
    /// (whatever the job's tier); when that is unavailable or disabled the list is empty (fail closed).
    public static func routes(job: JobType, config: RoutingConfig, catalog: [ModelInfo],
                              onDevice: OnDeviceAvailability, cloudAllowed: Bool = true) -> [Route] {
        let onDeviceRoute = Route(backend: .onDevice, model: FoundationModelsClient.modelID, effort: nil, tier: .onDevice)
        if !cloudAllowed || job == .meetingNotes {
            return config.onDeviceEnabled && onDevice == .available ? [onDeviceRoute] : []
        }
        let effort = job.defaultEffort
        func cloud(_ tier: Tier) -> Route? {
            ModelResolver.resolve(tier: tier, preferred: config.tierModels[tier], catalog: catalog)
                .map { Route(backend: .siwc, model: $0.slug, effort: effort, tier: tier) }
        }
        let tier = config.tier(for: job)
        var out: [Route] = []
        if tier == .onDevice {
            if config.onDeviceEnabled, onDevice == .available {
                out.append(onDeviceRoute)
            }
            if let r = cloud(.small) { out.append(r) }
        } else if let r = cloud(tier) {
            out.append(r)
        }
        return out
    }
}
