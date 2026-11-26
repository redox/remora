import Foundation

public enum MeetingClient: String, CaseIterable, Sendable {
    case googleMeet, zoom, teams

    public var displayName: String {
        switch self {
        case .googleMeet: "Google Meet"
        case .zoom: "Zoom"
        case .teams: "Microsoft Teams"
        }
    }

    var bundleIDs: [String] {
        switch self {
        case .googleMeet: ["com.google.Chrome"]
        case .zoom: ["us.zoom.xos"]
        case .teams: ["com.microsoft.teams2", "com.microsoft.teams"]
        }
    }

    func room(at url: URL?) -> String? {
        guard self == .googleMeet, let url, url.scheme?.lowercased() == "https",
              url.host()?.lowercased() == "meet.google.com", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let match = url.path(percentEncoded: true).wholeMatch(of: /\/([a-z]{3}-[a-z]{4}-[a-z]{3})\/?/) else {
            return nil
        }
        return String(match.1)
    }
}

public struct MeetingCaption: Equatable, Sendable {
    public let text: String
    public let speaker: String?

    public init(text: String, speaker: String? = nil) {
        self.text = text
        self.speaker = speaker
    }
}

/// The controller can retain this after discard to suppress restarting a stopped call
/// without retaining the window title, URL, captions or a provider meeting code.
public struct MeetingContinuity: Equatable, Sendable {
    public let id: String
    public let client: MeetingClient
    public let pid: pid_t
    public let bundleID: String
    let windowToken: String?
}

public struct VerifiedMeeting: Equatable, Sendable {
    public var continuity: MeetingContinuity {
        MeetingContinuity(id: id, client: client, pid: pid, bundleID: bundleID, windowToken: windowToken)
    }

    /// Opaque continuity token scoped to the running client. Never persist or log it.
    public let id: String
    public let client: MeetingClient
    public let pid: pid_t
    public let bundleID: String
    private let windowToken: String?
    public let context: WindowContext
    public let micAllowed: Bool
    public let captions: [MeetingCaption]

    public init(id: String, client: MeetingClient, pid: pid_t, bundleID: String, context: WindowContext,
                micAllowed: Bool, captions: [MeetingCaption], windowToken: String? = nil) {
        self.id = id
        self.client = client
        self.pid = pid
        self.bundleID = bundleID
        self.windowToken = windowToken
        self.context = context
        self.micAllowed = micAllowed
        self.captions = captions
    }
}

public enum MeetingDetection: Sendable, Equatable {
    case joined(VerifiedMeeting), left, unverifiable(MeetingVerificationIssue), denied
    /// A complete scan found no joined call, but the previous call could be in a background tab.
    case noVisibleCall
}

/// These messages identify the failed check without including a window title, meeting code or participant.
public enum MeetingVerificationIssue: Sendable, Equatable {
    case accessibility, scanTimedOut, clientIdentity(MeetingClient), windowList(MeetingClient)
    case chromeRole, chromeChildren, chromeWindowSize, chromePages, chromeProfile, controls(MeetingClient)
    case multipleCalls, sourceChanged

    public var message: String {
        switch self {
        case .accessibility: "Meeting recording could not read Accessibility information."
        case .scanTimedOut: "Meeting recording timed out while checking call windows."
        case .clientIdentity(let client): "Could not verify the running copy of \(client.displayName)."
        case .windowList(let client): "Could not check all \(client.displayName) windows for calls."
        case .chromeRole: "Chrome did not identify a window control during call verification."
        case .chromeChildren: "Chrome did not return the list of controls in part of a window."
        case .chromeWindowSize: "Chrome’s window exceeded the control limit for meeting verification."
        case .chromePages: "Could not isolate the Meet page in its Chrome window."
        case .chromeProfile: "Could not verify that Meet is in a regular Chrome profile."
        case .controls(let client): "Could not finish reading the call controls in \(client.displayName)."
        case .multipleCalls: "Meeting recording found more than one joined call."
        case .sourceChanged: "The call window changed during verification."
        }
    }
}

enum MeetingScanVerdict {
    /// A nil verdict means the single candidate can proceed to the final identity check.
    static func resolve(denied: Bool, issue: MeetingVerificationIssue?, candidates: Int,
                        previousProcessExists: Bool, previousLeft: Bool) -> MeetingDetection? {
        if denied { return .denied }
        if candidates > 1 { return .unverifiable(.multipleCalls) }
        if let issue { return .unverifiable(issue) }
        if candidates == 1 { return nil }
        return !previousProcessExists || previousLeft ? .left : .noVisibleCall
    }
}

enum ChromeMeetingWindow {
    /// Chrome shares a PID across windows. A known, regular sibling on another site cannot
    /// establish that the recorded call moved to an excluded page.
    static func blocksExcludedWindow(token: String, pid: pid_t, url: URL?, previous: MeetingContinuity?,
                                     regularSinglePage: @autoclosure () -> Bool) -> Bool {
        if MeetingClient.googleMeet.room(at: url) != nil { return true }
        guard let previous, previous.pid == pid else { return false }
        guard let original = previous.windowToken, url != nil else { return true }
        return original == token || !regularSinglePage()
    }

    /// Chrome appends its product name and, for multiple profiles, the native avatar name
    /// to the AX window title. Guest and incognito windows get a different suffix.
    static func regular(title: String?, pageTitle: String?, avatar: String?, knownToolbar: Bool = false) -> Bool {
        guard let title, !privateAvatar(avatar),
              !BrowserCatalog.looksPrivate(bundleID: "com.google.Chrome", windowTitle: title, chromeLabels: []) else { return false }
        if let pageTitle, !pageTitle.isEmpty, title.hasPrefix(pageTitle) {
            // Compare only what Chrome added to this exact page title. A page can include any of
            // these words in its own title, including what looks like a second browser suffix.
            let suffix = title.dropFirst(pageTitle.count).replacingOccurrences(of: "\u{a0}", with: " ")
            let product = " - Google Chrome"
            var endings = [product]
            if let avatar, !avatar.isEmpty {
                endings += [product + " - " + avatar, product + " – " + avatar]
            }
            if endings.contains(where: { ending in
                guard suffix.hasSuffix(ending) else { return false }
                let alert = String(suffix.dropLast(ending.count))
                return alert.isEmpty || mediaAlerts.contains(alert)
            }) { return true }
        }
        // Some macOS windows return only the page title. In this case both the
        // native profile avatar and Chrome's recognized toolbar must be present.
        return knownToolbar && avatar?.isEmpty == false
    }

    // Chromium localizes the tab alert before formatting the browser window title.
    private static let mediaAlerts: Set<String> = [
        " - Camera and microphone recording", " - Microphone recording", " - Camera recording",
        " - Audio playing", " - Audio muted", " - Tab content shared", " - Desktop content shared",
        " – Enregistrement de la caméra et du micro", " – Enregistrement du micro", " – Enregistrement de la caméra",
        " – Lecture audio", " – Contenu de l'onglet partagé", " – Contenu du bureau partagé",
    ]

    static func isAppMenuLabel(_ raw: String) -> Bool {
        let label = BrowserCatalog.fold(raw).replacingOccurrences(of: "\u{a0}", with: " ")
        return appMenuLabels.contains(label)
    }

    private static let appMenuLabels: Set<String> = [
        "customize and control google chrome", "customise and control google chrome",
        "customize and control google chrome. update is available.",
        "customise and control google chrome. update is available.",
        "customize and control google chrome. something needs your attention - click for details.",
        "customise and control google chrome. something needs your attention – click for details.",
        "personnaliser et controler google chrome",
        "personnalisez et controlez google chrome. une mise a jour est disponible.",
        "personnalisez et controlez google chrome. une action de votre part est requise. cliquez pour en savoir plus.",
    ]

    static func privateAvatar(_ avatar: String?) -> Bool {
        let markers = ["incognito", "private", "prive", "privee", "guest", "invite", "invitee", "isolated", "isole", "isolee"]
        let words = BrowserCatalog.fold(avatar ?? "").split { !$0.isLetter }.map(String.init)
        return words.contains(where: markers.contains)
    }
}

struct MeetingControls {
    private var hasExit = false
    private var hasCamera = false
    private var hasMute = false
    private var hasUnmute = false
    private var audioDisconnected = false
    private var hasJoinAction = false
    private var prejoin = false

    var joined: Bool { hasExit && (hasCamera || hasMute || hasUnmute) && !hasJoinAction && !prejoin }
    var micAllowed: Bool { joined && hasMute && !hasUnmute && !audioDisconnected }
    var left: Bool { hasJoinAction && !hasExit }

    /// A lobby can expose a camera preview, a mute button, and a way to leave at the same time.
    mutating func observePrejoinLabel(_ raw: String) {
        guard !prejoin else { return }
        let label = BrowserCatalog.fold(raw).trimmingCharacters(in: .punctuationCharacters)
        prejoin = Self.prejoinLabels.contains(label)
    }

    private static let prejoinLabels: Set<String> = [
            "ask to join", "join now", "cancel request", "ready to join", "waiting room", "you're in the lobby",
            "you’re in the lobby", "waiting for the host to start this meeting", "waiting for the host to let you in",
            "audio and video preview", "test speaker and microphone", "rejoindre maintenant",
            "demander a participer", "annuler la demande", "salle d'attente", "salle d’attente",
    ]

    mutating func observe(button: String, client: MeetingClient, mediaToggle: Bool = false) {
        // Strip only a parenthesized shortcut. Participant names and other arbitrary
        // suffixes must never turn a participant's mute button into our own mic state.
        let folded = BrowserCatalog.fold(button)
        let label = folded.replacing(/\s*\((?:⌘|cmd|command|ctrl|control|maj|shift)[+ a-z⌘⇧-]*\)$/, with: "")
        if !mediaToggle, ["rejoin", "rejoindre a nouveau", "reparticiper"].contains(label) { hasJoinAction = true }
        if ["join audio", "connect audio", "join computer audio", "rejoindre l’audio", "rejoindre l'audio",
            "connecter l’audio", "connecter l'audio"].contains(label) { audioDisconnected = true }
        switch client {
        case .googleMeet:
            if !mediaToggle, ["join now", "ask to join", "rejoindre maintenant", "demander a participer"].contains(label) {
                hasJoinAction = true
            }
            observe(label, exit: mediaToggle ? [] : ["leave call", "quitter l'appel", "quitter l’appel"],
                    camera: ["turn on camera", "turn off camera", "activer la camera", "desactiver la camera"],
                    mute: ["turn off microphone", "desactiver le micro", "couper le micro"],
                    unmute: ["turn on microphone", "activer le micro", "reactiver le micro"])
        case .zoom:
            observe(label, exit: ["leave", "end", "leave meeting", "end meeting", "quitter", "fin",
                                   "quitter la reunion", "mettre fin a la reunion"],
                    camera: ["start video", "stop video", "demarrer la video", "arreter la video"],
                    mute: ["mute", "mute audio", "mute my audio", "couper le son", "couper mon audio", "desactiver le son"],
                    unmute: ["unmute", "unmute audio", "unmute my audio", "retablir le son", "retablir mon audio", "reactiver le son"])
        case .teams:
            observe(label, exit: ["leave", "leave call", "hang up", "quitter", "raccrocher"],
                    camera: ["turn camera on", "turn camera off", "activer la camera", "desactiver la camera"],
                    mute: ["mute", "mute mic", "mute microphone", "desactiver le micro", "couper le son"],
                    unmute: ["unmute", "unmute mic", "unmute microphone", "activer le micro", "retablir le son"])
        }
    }

    private mutating func observe(_ label: String, exit: [String], camera: [String],
                                  mute: [String], unmute: [String]) {
        hasExit = hasExit || exit.contains(label)
        hasCamera = hasCamera || camera.contains(label)
        hasMute = hasMute || mute.contains(label)
        hasUnmute = hasUnmute || unmute.contains(label)
    }
}
