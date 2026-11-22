import AppKit
import Foundation
import LLM
import Observation
import os
import Storage
import Synchronization

/// The routing and model list as the (non-isolated) `LLMService` reads them.
final class LLMSnapshotBox: Sendable {
    private struct Value: Sendable { var routing: RoutingConfig; var catalog: [ModelInfo] }
    private let value: Mutex<Value>

    init(routing: RoutingConfig, catalog: [ModelInfo]) { value = Mutex(Value(routing: routing, catalog: catalog)) }

    var routing: RoutingConfig {
        get { value.withLock { $0.routing } }
        set { value.withLock { $0.routing = newValue } }
    }

    var catalog: [ModelInfo] {
        get { value.withLock { $0.catalog } }
        set { value.withLock { $0.catalog = newValue } }
    }
}

struct SystemBrowser: BrowserOpening {
    func open(_ url: URL) -> Bool { NSWorkspace.shared.open(url) }
}

/// Sign-in state, model list, tier choices and job routing for Settings, the menu and onboarding.
/// Never logs emails, tokens or error text.
@MainActor @Observable
final class AccountModel {
    private(set) var state: SignInState = .signedOut
    private(set) var isSigningIn = false
    /// A user-facing line about the last sign-in or account action; nil when there is nothing to say.
    var lastError: String?
    private(set) var catalog: [ModelInfo] = []
    var routing: RoutingConfig {
        didSet {
            guard routing != oldValue else { return }
            box.routing = routing
            persistRouting()
        }
    }
    private(set) var onDevice: OnDeviceAvailability
    /// True after the first successful sign-in with plan usage (shown once: `llm.welcomeShown`).
    var showWelcome = false

    var presentation: AccountPresentation { AccountPresentation(state) }

    @ObservationIgnored var onWelcome: (@MainActor () -> Void)?

    @ObservationIgnored private let tokens: TokenManager
    @ObservationIgnored private let flow: SignInFlow
    @ObservationIgnored private let models: ModelCatalog
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let onDeviceModel: any OnDeviceModel
    @ObservationIgnored private let box: LLMSnapshotBox
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var started = false
    private static let welcomeKey = "llm.welcomeShown"
    private static let log = Logger(subsystem: "dev.remora", category: "account")

    init(tokens: TokenManager, flow: SignInFlow, models: ModelCatalog, settings: SettingsStore,
         onDeviceModel: any OnDeviceModel, box: LLMSnapshotBox) {
        self.tokens = tokens
        self.flow = flow
        self.models = models
        self.settings = settings
        self.onDeviceModel = onDeviceModel
        self.box = box
        routing = box.routing
        catalog = box.catalog
        onDevice = onDeviceModel.availability
    }

    /// Loads the saved routing (a corrupt value is ignored and replaced on the next change).
    static func loadRouting(_ settings: SettingsStore) -> RoutingConfig {
        do { return try settings.value(RoutingConfig.self, forKey: RoutingConfig.settingKey) ?? RoutingConfig() } catch {
            log.error("routing setting unreadable; using defaults")
            return RoutingConfig()
        }
    }

    // MARK: - Lifecycle

    /// Refreshes at launch, every 10 minutes and after wake. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        let timer = Timer(timeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.maintain() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.maintain() }
        }
        applyCatalog()
        maintain()
    }

    private func maintain() {
        Task { [weak self] in
            guard let self else { return }
            await tokens.refreshIfDue()
            await refreshState()
            await refreshCatalogIfStale()
        }
    }

    /// Re-reads the sign-in state and on-device availability (also the Retry action).
    func refreshState() async {
        state = await tokens.state()
        onDevice = onDeviceModel.availability
    }

    func retry() { Task { await refreshState() } }

    // MARK: - Sign-in

    func signIn() async {
        guard !isSigningIn, presentation.offersContinue else { return }
        isSigningIn = true
        lastError = nil
        let flow = flow
        let task = Task { [weak self] in
            do {
                let account = try await flow.signIn()
                await self?.signedIn(planUsage: account.planUsageEnabled)
            } catch {
                await self?.signInFailed(error)
            }
        }
        signInTask = task
        await task.value
    }

    func cancelSignIn() { signInTask?.cancel() }

    private func signedIn(planUsage: Bool) async {
        isSigningIn = false
        signInTask = nil
        await refreshState()
        if planUsage {
            await refreshCatalog()
            let shown = (try? settings.value(Bool.self, forKey: Self.welcomeKey)) ?? false
            if !shown {
                do { try settings.setValue(true, forKey: Self.welcomeKey) } catch {
                    Self.log.error("welcome flag not saved")
                }
                showWelcome = true
                onWelcome?()
            }
        }
    }

    private func signInFailed(_ error: any Error) async {
        isSigningIn = false
        signInTask = nil
        lastError = AccountPresentation.message(for: error)
        await refreshState()
    }

    func signOut() {
        Task {
            do {
                try await tokens.signOut()
                lastError = nil
            } catch {
                Self.log.error("sign-out failed")
                lastError = "Could not sign out. Try again."
            }
            await refreshState()
        }
    }

    /// Advanced: signs out and forgets the issued client id and host id, so the next sign-in registers
    /// this Mac again.
    func forgetRegistration() {
        // A sign-in still finishing could store a registration after it is forgotten: wait for it.
        let pending = signInTask
        pending?.cancel()
        Task {
            await pending?.value
            do {
                try await tokens.forgetRegistration()
                lastError = nil
            } catch {
                Self.log.error("forget registration failed")
                lastError = "Could not reset this Mac's registration. Try again."
            }
            await refreshState()
        }
    }

    // MARK: - Models and routing

    func refreshCatalog() async {
        _ = try? await models.refresh()
        applyCatalog()
    }

    private func refreshCatalogIfStale() async {
        await models.refreshIfStale()
        applyCatalog()
    }

    private func applyCatalog() {
        Task { [weak self] in
            guard let self else { return }
            let cached = await models.cached().models
            catalog = cached
            box.catalog = cached
        }
    }

    func setModel(_ slug: String?, for tier: Tier) {
        guard tier != .onDevice else { return }
        if let slug, !slug.isEmpty { routing.tierModels[tier] = slug } else { routing.tierModels[tier] = nil }
    }

    func setTier(_ tier: Tier, for job: JobType) {
        if tier == job.defaultTier { routing.jobTiers[job] = nil } else { routing.jobTiers[job] = tier }
    }

    func resetJobRouting() { routing.jobTiers = [:] }

    func resolved(_ tier: Tier) -> ResolvedModel? {
        ModelResolver.resolve(tier: tier, preferred: routing.tierModels[tier], catalog: catalog)
    }

    /// What "Automatic" means for a tier right now.
    func automaticSlug(_ tier: Tier) -> String? {
        ModelResolver.resolve(tier: tier, preferred: nil, catalog: catalog)?.slug
    }

    private func persistRouting() {
        do { try settings.setValue(routing, forKey: RoutingConfig.settingKey) } catch {
            Self.log.error("routing not saved")
            lastError = "Could not save the model settings."
        }
    }
}

extension Tier {
    var title: String {
        switch self { case .onDevice: "On-device"; case .small: "Small"; case .large: "Large" }
    }
}

extension JobType {
    var title: String {
        let words = rawValue.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
