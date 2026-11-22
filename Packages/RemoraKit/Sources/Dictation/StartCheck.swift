import Foundation
import Rewrite

public enum MicrophoneStatus: Sendable, Equatable { case notDetermined, denied, restricted, granted }

/// A nil install fraction means the system is downloading without exposing progress to Remora.
public enum AssetState: Sendable, Equatable { case unknown, notInstalled, installing(Double?), installed, unsupported, failed(String) }

public enum NoticeAction: Sendable, Equatable { case openMicrophoneSettings, openDictationSettings }

/// Short notes shown by the dictation HUD. Carry no transcript content.
public enum DictationNotice: Sendable, Equatable {
    case microphoneDenied, microphoneRequested, unsupported
    case assetDownloading(DictationLocale, Double?)
    case assetMissing(DictationLocale), localeUnsupported(DictationLocale)
    case nothingHeard, cleanupSkipped, secureField, copiedInstead, limitReached, microphoneLost, failed
    case openAITranscriptionUnavailable

    public var text: String {
        switch self {
        case .microphoneDenied: "Microphone access is off for Remora."
        case .microphoneRequested: "Allow microphone access to dictate."
        case .unsupported: "Speech recognition isn't available on this Mac."
        case .assetDownloading(let l, let p):
            "Downloading the \(l.name) speech model…" + (p.map { " \(Int(($0 * 100).rounded(.down)))%" } ?? "")
        case .assetMissing(let l): "The \(l.name) speech model isn't installed yet. Downloading…"
        case .localeUnsupported(let l): "\(l.name) dictation isn't supported on this Mac."
        case .nothingHeard: "Didn't catch that."
        case .cleanupSkipped: "Inserted without cleanup."
        case .openAITranscriptionUnavailable: "OpenAI transcription unavailable. Used this Mac."
        case .secureField: "Can't dictate into a password field."
        case .copiedInstead: "Couldn't insert here. Copied to the clipboard."
        case .limitReached: "Stopped after 5 minutes."
        case .microphoneLost: "Microphone disconnected. Stopped listening."
        case .failed: "Dictation stopped unexpectedly."
        }
    }

    public var action: NoticeAction? {
        switch self {
        case .microphoneDenied: .openMicrophoneSettings
        case .assetMissing, .openAITranscriptionUnavailable: .openDictationSettings
        default: nil
        }
    }
}

public struct StartConditions: Sendable, Equatable {
    public var enabled: Bool
    public var sessionActive: Bool
    public var rewriteBusy: Bool
    public var transcriberAvailable: Bool
    public var microphone: MicrophoneStatus
    /// For the chosen locale.
    public var asset: AssetState

    public init(enabled: Bool, sessionActive: Bool, rewriteBusy: Bool, transcriberAvailable: Bool,
                microphone: MicrophoneStatus, asset: AssetState) {
        self.enabled = enabled; self.sessionActive = sessionActive; self.rewriteBusy = rewriteBusy
        self.transcriberAvailable = transcriberAvailable; self.microphone = microphone; self.asset = asset
    }
}

public enum StartDecision: Sendable, Equatable { case start, ignore, requestMicrophone, refuse(DictationNotice) }

public enum StartCheck {
    public static func evaluate(_ c: StartConditions, locale: DictationLocale) -> StartDecision {
        if !c.enabled || c.sessionActive || c.rewriteBusy { return .ignore }
        if !c.transcriberAvailable { return .refuse(.unsupported) }
        switch c.microphone {
        case .notDetermined: return .requestMicrophone
        case .denied, .restricted: return .refuse(.microphoneDenied)
        case .granted: break
        }
        switch c.asset {
        case .installed: return .start
        case .installing(let p): return .refuse(.assetDownloading(locale, p))
        case .unsupported: return .refuse(.localeUnsupported(locale))
        case .unknown, .notInstalled, .failed: return .refuse(.assetMissing(locale))
        }
    }
}

/// Where the dictated text goes.
public enum DictationTarget: Sendable, Equatable {
    case field, frontmostPaste, refuseSecure, nowhere

    public static func decide(fieldPresent: Bool, isSecure: Bool, frontmostIsSelf: Bool) -> DictationTarget {
        if isSecure { return .refuseSecure }
        if fieldPresent { return .field }
        return frontmostIsSelf ? .nowhere : .frontmostPaste
    }
}

/// How the transcript may be cleaned, derived from Plan 2's rewrite privacy gate so dictation and
/// rewrites share one rule: refused contexts (password managers, vaults, unverifiable browser
/// pages) never dictate; excluded/private/unverifiable contexts clean on-device only (unavailable
/// means the raw transcript is inserted, never the cloud); paused or normal contexts may use the
/// cloud with the transcript only.
public enum CleanupRoute: Sendable, Equatable {
    case refuse, onDeviceOnly, cloud

    /// `gate == nil` means the context could not be evaluated: fail closed to on-device.
    public init(gate: RewriteGate?) {
        switch gate {
        case nil: self = .onDeviceOnly
        case .refuse?: self = .refuse
        case .proceed(let access)?: self = access.cloudAllowed ? .cloud : .onDeviceOnly
        }
    }

    public var cloudAllowed: Bool { self == .cloud }
}
