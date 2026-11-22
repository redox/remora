import Foundation
import Observation

/// Mirrors `AssetInventory.Status` (`.supported` is "not installed yet").
public enum AssetStatus: Sendable, Equatable { case unsupported, notInstalled, downloading, installed }

public protocol SpeechAssets: Sendable {
    func transcriberAvailable() -> Bool
    func status(_ l: DictationLocale) async -> AssetStatus
    /// Downloads and installs the locale's model, reporting fraction completed in 0...1.
    func install(_ l: DictationLocale, progress: @escaping @Sendable (Double) -> Void) async throws
}

public protocol MicrophonePermission: Sendable {
    func status() -> MicrophoneStatus
    func request() async -> Bool
}

/// Per-locale install state for Settings and the start check. Only installs when asked (never on
/// refresh), one install in flight per locale.
@MainActor @Observable
public final class SpeechAssetModel {
    public static let failureMessage = "Download failed. Check your connection and try again."
    public static let tooManyLanguagesMessage = "Too many speech languages reserved. Remove one in System Settings and try again."

    public private(set) var states: [DictationLocale: AssetState] = [:]
    public private(set) var transcriberAvailable: Bool

    @ObservationIgnored private let assets: any SpeechAssets
    /// Per-locale attempt token: bumped by every install, so a late progress callback of an earlier
    /// attempt can't overwrite the state of a retry.
    @ObservationIgnored private var attempts: [DictationLocale: Int] = [:]
    /// Locales with an install of ours in flight (a download started elsewhere is not in here).
    @ObservationIgnored private var inFlight: Set<DictationLocale> = []

    public init(assets: any SpeechAssets) {
        self.assets = assets
        transcriberAvailable = assets.transcriberAvailable()
    }

    public func state(_ l: DictationLocale) -> AssetState { states[l] ?? .unknown }

    /// An install of ours is running for `l` (a download started elsewhere is not).
    public func installInFlight(_ l: DictationLocale) -> Bool { inFlight.contains(l) }

    public func refresh() async {
        transcriberAvailable = assets.transcriberAvailable()
        for l in DictationLocale.allCases {
            if transcriberAvailable, inFlight.contains(l) { continue } // keep our own in-flight install
            guard transcriberAvailable else { states[l] = .unsupported; continue }
            let attempt = attempts[l]
            let status = await assets.status(l)
            // An install began (and maybe finished) while we awaited: this read is stale.
            if inFlight.contains(l) || attempts[l] != attempt { continue }
            switch status {
            case .installed: states[l] = .installed
            case .notInstalled:
                // A refresh is not a retry: keep the explanation until another attempt or a
                // system status change replaces it.
                if case .failed = state(l) { continue }
                states[l] = .notInstalled
            case .downloading: states[l] = .installing(nil)
            case .unsupported: states[l] = .unsupported
            }
        }
    }

    public func install(_ l: DictationLocale) async {
        guard transcriberAvailable else { return }
        switch state(l) {
        case .installed, .unsupported, .installing: return
        case .unknown, .notInstalled, .failed: break
        }
        let attempt = (attempts[l] ?? 0) + 1
        attempts[l] = attempt
        inFlight.insert(l)
        defer { inFlight.remove(l) }
        states[l] = .installing(0)
        do {
            try await assets.install(l) { [weak self] p in
                Task { @MainActor in self?.apply(progress: p, to: l, attempt: attempt) }
            }
            states[l] = .installed
        } catch is CancellationError {
            states[l] = .notInstalled
        } catch DictationError.tooManyReservedLanguages {
            states[l] = .failed(Self.tooManyLanguagesMessage)
        } catch {
            states[l] = .failed(Self.failureMessage)
        }
    }

    public func installMissing() async {
        for l in DictationLocale.allCases {
            switch state(l) {
            case .notInstalled, .failed: await install(l)
            default: break
            }
        }
    }

    private func apply(progress p: Double, to l: DictationLocale, attempt: Int) {
        guard attempts[l] == attempt, case .installing = state(l) else { return }
        states[l] = .installing(min(max(p, 0), 1))
    }
}

/// `AssetInventory.reserve(locale:)` returns false when the app is at its reserved-language limit;
/// that is fine only when the locale is already reserved.
public enum LocaleReservation {
    public static func verify(granted: Bool, reserved: [Locale], locale: Locale) throws(DictationError) {
        if granted { return }
        let id = locale.identifier(.bcp47)
        guard reserved.contains(where: { $0.identifier(.bcp47) == id }) else { throw .tooManyReservedLanguages }
    }
}
