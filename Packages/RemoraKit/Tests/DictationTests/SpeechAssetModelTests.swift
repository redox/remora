import Foundation
import Synchronization
import Testing
@testable import Dictation

/// Fake speech assets: per-locale statuses, scripted progress, an optional error, and an optional gate
/// that holds an install open until the test releases it.
final class FakeSpeechAssets: SpeechAssets {
    private struct State {
        var statuses: [DictationLocale: AssetStatus]
        var progress: [Double] = []
        var failures = 0
        var gated = false
        var released = false
        var calls: [DictationLocale: Int] = [:]
        /// `status(_:)` for this locale reads the status, then waits for `releaseStatus()`.
        var statusGate: DictationLocale?
        var statusWaiting = false
    }
    private let state: Mutex<State>
    private let available: Bool

    init(statuses: [DictationLocale: AssetStatus] = [:], available: Bool = true, gated: Bool = false,
         progress: [Double] = [], failures: Int = 0) {
        self.available = available
        state = Mutex(State(statuses: statuses, progress: progress, failures: failures, gated: gated))
    }

    var installCalls: [DictationLocale: Int] { state.withLock { $0.calls } }
    func release() { state.withLock { $0.released = true } }
    func gateStatus(_ l: DictationLocale) { state.withLock { $0.statusGate = l } }
    func releaseStatus() { state.withLock { $0.statusGate = nil } }
    var statusWaiting: Bool { state.withLock { $0.statusWaiting } }

    func transcriberAvailable() -> Bool { available }
    func status(_ l: DictationLocale) async -> AssetStatus {
        let read = state.withLock { $0.statuses[l] ?? .notInstalled }
        guard state.withLock({ $0.statusGate == l }) else { return read }
        state.withLock { $0.statusWaiting = true }
        while state.withLock({ $0.statusGate == l }) { try? await Task.sleep(for: .milliseconds(5)) }
        state.withLock { $0.statusWaiting = false }
        return read
    }

    func install(_ l: DictationLocale, progress: @escaping @Sendable (Double) -> Void) async throws {
        let script = state.withLock { s -> [Double] in s.calls[l, default: 0] += 1; return s.progress }
        for p in script { progress(p) }
        while state.withLock({ $0.gated && !$0.released }) { try await Task.sleep(for: .milliseconds(5)) }
        let fail = state.withLock { s -> Bool in
            guard s.failures > 0 else { return false }
            s.failures -= 1
            return true
        }
        if fail { throw URLError(.notConnectedToInternet) }
        state.withLock { $0.statuses[l] = .installed }
    }
}

@MainActor private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
}

@MainActor @Test func refreshMapsStatuses() async {
    let model = SpeechAssetModel(assets: FakeSpeechAssets(statuses: [.fr: .installed, .en: .notInstalled]))
    await model.refresh()
    #expect(model.states == [.fr: .installed, .en: .notInstalled])
    let busy = SpeechAssetModel(assets: FakeSpeechAssets(statuses: [.fr: .downloading, .en: .unsupported]))
    await busy.refresh()
    #expect(busy.states == [.fr: .installing(nil), .en: .unsupported])
}

@MainActor @Test func anExternalDownloadDoesNotInventAProgressPercentage() async {
    let model = SpeechAssetModel(assets: FakeSpeechAssets(statuses: [.fr: .downloading]))
    await model.refresh()
    guard case .installing(let progress) = model.state(.fr) else {
        Issue.record("Expected a download in progress")
        return
    }
    #expect(DictationNotice.assetDownloading(.fr, progress).text == "Downloading the French speech model…")
}

/// A refresh that read "downloading" before an install of ours began and finished must not
/// overwrite the newer `.installed` with a stale "Downloading 0%".
@MainActor @Test func staleRefreshDoesNotOverwriteAFinishedInstall() async {
    let fake = FakeSpeechAssets(statuses: [.fr: .downloading, .en: .installed])
    fake.gateStatus(.fr)
    let model = SpeechAssetModel(assets: fake)
    let refreshing = Task { await model.refresh() }
    await waitUntil { fake.statusWaiting }
    #expect(fake.statusWaiting)
    await model.install(.fr)
    #expect(model.state(.fr) == .installed)
    fake.releaseStatus()
    await refreshing.value
    #expect(model.state(.fr) == .installed)
    #expect(!model.installInFlight(.fr))
}

/// The start check refreshes a "downloading" state only when no install of ours is running.
@MainActor @Test func installInFlightTracksOurInstallOnly() async {
    let fake = FakeSpeechAssets(statuses: [.fr: .notInstalled], gated: true)
    let model = SpeechAssetModel(assets: fake)
    await model.refresh()
    #expect(!model.installInFlight(.fr))
    let task = Task { await model.install(.fr) }
    await waitUntil { fake.installCalls[.fr] == 1 }
    #expect(model.installInFlight(.fr))
    fake.release()
    await task.value
    #expect(!model.installInFlight(.fr))
    let elsewhere = SpeechAssetModel(assets: FakeSpeechAssets(statuses: [.fr: .downloading]))
    await elsewhere.refresh()
    #expect(elsewhere.state(.fr) == .installing(nil) && !elsewhere.installInFlight(.fr))
}

@MainActor @Test func installReportsProgressThenInstalled() async {
    let fake = FakeSpeechAssets(statuses: [.fr: .notInstalled], gated: true, progress: [0.25, 0.5])
    let model = SpeechAssetModel(assets: fake)
    await model.refresh()
    let task = Task { await model.install(.fr) }
    await waitUntil { model.state(.fr) == .installing(0.5) }
    #expect(model.state(.fr) == .installing(0.5))
    fake.release()
    await task.value
    #expect(model.state(.fr) == .installed)
}

@MainActor @Test func installFailureIsRetryable() async {
    let fake = FakeSpeechAssets(statuses: [.fr: .notInstalled], failures: 1)
    let model = SpeechAssetModel(assets: fake)
    await model.refresh()
    await model.install(.fr)
    #expect(model.state(.fr) == .failed("Download failed. Check your connection and try again."))
    await model.install(.fr)
    #expect(model.state(.fr) == .installed)
}

@MainActor @Test func refreshingAnUninstalledModelPreservesItsDownloadFailure() async {
    let assets = FakeSpeechAssets(failures: 1)
    let model = SpeechAssetModel(assets: assets)
    await model.install(.fr)
    await model.refresh()
    #expect(model.state(.fr) == .failed(SpeechAssetModel.failureMessage))
    await model.install(.fr)
    #expect(model.state(.fr) == .installed)
}

@MainActor @Test func concurrentInstallsShareOne() async {
    let fake = FakeSpeechAssets(statuses: [.fr: .notInstalled], gated: true)
    let model = SpeechAssetModel(assets: fake)
    await model.refresh()
    let first = Task { await model.install(.fr) }
    await waitUntil { fake.installCalls[.fr] == 1 }
    await model.install(.fr)
    fake.release()
    await first.value
    #expect(fake.installCalls[.fr] == 1)
    #expect(model.state(.fr) == .installed)
}

@MainActor @Test func unsupportedNeverInstalls() async {
    let fake = FakeSpeechAssets(statuses: [.fr: .installed, .en: .unsupported])
    let model = SpeechAssetModel(assets: fake)
    await model.refresh()
    await model.installMissing()
    await model.install(.en)
    #expect(fake.installCalls[.en] == nil)
    #expect(fake.installCalls[.fr] == nil)
}

@MainActor @Test func installMissingInstallsNotInstalledAndFailedInOrder() async {
    let fake = FakeSpeechAssets(statuses: [.fr: .notInstalled, .en: .notInstalled], failures: 1)
    let model = SpeechAssetModel(assets: fake)
    await model.refresh()
    await model.installMissing()
    #expect(model.state(.fr) == .failed("Download failed. Check your connection and try again."))
    #expect(model.state(.en) == .installed)
    await model.installMissing()
    #expect(model.state(.fr) == .installed)
    #expect(fake.installCalls == [.fr: 2, .en: 1])
}

@MainActor @Test func transcriberUnavailableMarksAllUnsupported() async {
    let fake = FakeSpeechAssets(statuses: [.fr: .installed, .en: .installed], available: false)
    let model = SpeechAssetModel(assets: fake)
    await model.refresh()
    #expect(model.transcriberAvailable == false)
    #expect(model.states == [.fr: .unsupported, .en: .unsupported])
    await model.install(.fr)
    #expect(fake.installCalls[.fr] == nil)
}

@Test func reservationFalseWithoutReservedLocaleThrows() {
    let fr = Locale(identifier: "fr-FR"), en = Locale(identifier: "en-US")
    #expect(throws: DictationError.tooManyReservedLanguages) { try LocaleReservation.verify(granted: false, reserved: [en], locale: fr) }
    #expect(throws: Never.self) { try LocaleReservation.verify(granted: false, reserved: [fr], locale: fr) }
    #expect(throws: Never.self) { try LocaleReservation.verify(granted: true, reserved: [], locale: fr) }
    #expect(DictationError.tooManyReservedLanguages.errorDescription?.contains("Too many speech languages reserved") == true)
}

@MainActor @Test func cancelledInstallBecomesNotInstalled() async {
    final class Cancelling: SpeechAssets {
        func transcriberAvailable() -> Bool { true }
        func status(_ l: DictationLocale) async -> AssetStatus { .notInstalled }
        func install(_ l: DictationLocale, progress: @escaping @Sendable (Double) -> Void) async throws { throw CancellationError() }
    }
    let model = SpeechAssetModel(assets: Cancelling())
    await model.refresh()
    await model.install(.fr)
    #expect(model.state(.fr) == .notInstalled)
}

@MainActor @Test func tooManyLanguagesShowsItsOwnMessage() async {
    final class Full: SpeechAssets {
        func transcriberAvailable() -> Bool { true }
        func status(_ l: DictationLocale) async -> AssetStatus { .notInstalled }
        func install(_ l: DictationLocale, progress: @escaping @Sendable (Double) -> Void) async throws { throw DictationError.tooManyReservedLanguages }
    }
    let model = SpeechAssetModel(assets: Full())
    await model.refresh()
    await model.install(.fr)
    #expect(model.state(.fr) == .failed(SpeechAssetModel.tooManyLanguagesMessage))
}

/// Hands each install attempt's progress callback to the test and finishes the attempt on demand.
private final class ScriptedAssets: SpeechAssets {
    private struct S {
        var status: AssetStatus
        var handlers: [@Sendable (Double) -> Void] = []
        var continuations: [CheckedContinuation<Void, any Error>] = []
    }
    private let s: Mutex<S>
    init(status: AssetStatus) { s = Mutex(S(status: status)) }
    var attempts: Int { s.withLock { $0.handlers.count } }
    func setStatus(_ v: AssetStatus) { s.withLock { $0.status = v } }
    func report(attempt: Int, _ p: Double) { s.withLock { $0.handlers[attempt] }(p) }
    func finish(attempt: Int, error: (any Error)?) {
        let c = s.withLock { $0.continuations[attempt] }
        if let error { c.resume(throwing: error) } else { c.resume() }
    }
    func transcriberAvailable() -> Bool { true }
    func status(_ l: DictationLocale) async -> AssetStatus { s.withLock { $0.status } }
    func install(_ l: DictationLocale, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await withCheckedThrowingContinuation { c in
            s.withLock { $0.handlers.append(progress); $0.continuations.append(c) }
        }
    }
}

@MainActor @Test func staleProgressFromAnEarlierAttemptIsIgnoredAfterRetry() async {
    let assets = ScriptedAssets(status: .notInstalled)
    let model = SpeechAssetModel(assets: assets)
    await model.refresh()
    let first = Task { await model.install(.fr) }
    await waitUntil { assets.attempts == 1 }
    assets.report(attempt: 0, 0.8)
    await waitUntil { model.state(.fr) == .installing(0.8) }
    assets.finish(attempt: 0, error: URLError(.notConnectedToInternet))
    await first.value
    #expect(model.state(.fr) == .failed(SpeechAssetModel.failureMessage))
    let second = Task { await model.install(.fr) }
    await waitUntil { assets.attempts == 2 }
    #expect(model.state(.fr) == .installing(0))
    assets.report(attempt: 0, 0.9) // a late callback of the failed attempt
    for _ in 0..<10 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(30))
    #expect(model.state(.fr) == .installing(0))
    assets.report(attempt: 1, 0.3)
    await waitUntil { model.state(.fr) == .installing(0.3) }
    #expect(model.state(.fr) == .installing(0.3))
    assets.setStatus(.installed)
    assets.finish(attempt: 1, error: nil)
    await second.value
    #expect(model.state(.fr) == .installed)
}

@MainActor @Test func refreshFollowsADownloadStartedElsewhereToInstalled() async {
    let assets = ScriptedAssets(status: .downloading)
    let model = SpeechAssetModel(assets: assets)
    await model.refresh()
    #expect(model.state(.fr) == .installing(nil))
    assets.setStatus(.installed)
    await model.refresh()
    #expect(model.state(.fr) == .installed)
}

@MainActor @Test func refreshKeepsOwnInFlightInstall() async {
    let assets = ScriptedAssets(status: .notInstalled)
    let model = SpeechAssetModel(assets: assets)
    await model.refresh()
    let task = Task { await model.install(.fr) }
    await waitUntil { assets.attempts == 1 }
    assets.report(attempt: 0, 0.5)
    await waitUntil { model.state(.fr) == .installing(0.5) }
    await model.refresh()
    #expect(model.state(.fr) == .installing(0.5))
    assets.setStatus(.installed)
    assets.finish(attempt: 0, error: nil)
    await task.value
}
