import Foundation
import os
import Speech

/// Speech model install through `AssetInventory`. Nothing here runs until the app asks (Settings or
/// the first-use flow); there is no work at module load.
public struct SystemSpeechAssets: SpeechAssets {
    private static let log = Logger(subsystem: "dev.remora", category: "dictation")

    public init() {}

    public func transcriberAvailable() -> Bool { SpeechTranscriber.isAvailable }

    public func status(_ l: DictationLocale) async -> AssetStatus {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: l.locale) else { return .unsupported }
        switch await AssetInventory.status(forModules: [SpeechAnalyzerTranscriber.makeModule(locale)]) {
        case .unsupported: return .unsupported
        case .supported: return .notInstalled
        case .downloading: return .downloading
        case .installed: return .installed
        @unknown default: return .unsupported
        }
    }

    public func install(_ l: DictationLocale, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: l.locale) else {
            throw DictationError.noCompatibleFormat
        }
        let module = SpeechAnalyzerTranscriber.makeModule(locale)
        let granted = try await AssetInventory.reserve(locale: locale)
        try LocaleReservation.verify(granted: granted, reserved: await AssetInventory.reservedLocales, locale: locale)
        // nil: nothing left to download.
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
            progress(1)
            return
        }
        let poller = Task {
            while !Task.isCancelled {
                progress(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { poller.cancel() }
        try await request.downloadAndInstall()
        progress(1)
        Self.log.info("speech assets installed locale=\(l.rawValue, privacy: .public)")
    }
}
