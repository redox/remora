import AppKit
import ApplicationServices
import Security

public struct MeetingDetector: Sendable {
    public init() {}

    /// Supply freshly loaded policy on each observation. Missing AX or a switch to a
    /// different Chrome tab cannot prove the previous call ended.
    public func detect(policy: CapturePolicy, previous: MeetingContinuity? = nil) async -> MeetingDetection {
        guard !policy.deniesEverything else { return .denied }
        let result = try? await AXQueue.run { session in
            Self.scan(policy: policy, previous: previous, session: session)
        }
        return result ?? .unverifiable(.accessibility)
    }

    private struct Candidate {
        let id: String
        let client: MeetingClient
        let pid: pid_t
        let bundleID: String
        let context: WindowContext
        let window: SystemAXNode
        let windowToken: String
        let webArea: SystemAXNode?
        let captionRegions: [SystemAXNode]
        let micAllowed: Bool
    }

    private struct Observation {
        var candidates: [Candidate] = []
        var issue: MeetingVerificationIssue?
        var denied = false
        var previousProcessExists = false
        var previousLeft = false
    }

    /// A busy discovery pass can leave too little time to read even an unchanged Chrome
    /// window a second time. Only completed discovery gets this bounded final verification.
    static func finalDeadline(for client: MeetingClient, discoveredAt: ContinuousClock.Instant,
                              discoveryDeadline: ContinuousClock.Instant) -> ContinuousClock.Instant {
        client == .googleMeet ? max(discoveryDeadline, discoveredAt + .milliseconds(750)) : discoveryDeadline
    }

    private static func scan(policy: CapturePolicy, previous: MeetingContinuity?, session: AXReadSession) -> MeetingDetection {
        guard AXIsProcessTrusted() else { return .unverifiable(.accessibility) }
        var observation = Observation()
        let deadline = ContinuousClock.now + .seconds(2)
        for client in MeetingClient.allCases {
            for bundleID in client.bundleIDs {
                let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                for app in apps where !app.isTerminated {
                    guard !session.isCancelled, !session.isUnresponsive, ContinuousClock.now < deadline else {
                        return .unverifiable(.scanTimedOut)
                    }
                    let pid = app.processIdentifier
                    let wasRecording = previous?.pid == pid && previous?.bundleID == bundleID
                    observation.previousProcessExists = observation.previousProcessExists || wasRecording
                    let context = WindowContext(app: app.localizedName ?? bundleID, bundleID: bundleID)
                    guard policy.appVerdict(context) == .allowed else {
                        if wasRecording { return .denied }
                        continue
                    }
                    guard pid != getpid(), trusted(pid: pid, client: client, bundleID: bundleID) else {
                        observation.issue = .clientIdentity(client)
                        continue
                    }
                    AppAccessibility.enable(app, session: session)
                    let element = SystemAXNode(AXUIElementCreateApplication(pid), session: session)
                    guard let windows = session.copyElements(element.element, kAXWindowsAttribute, max: 17),
                          windows.count <= 16 else {
                        observation.issue = .windowList(client)
                        continue
                    }
                    var previousWindowExists = false
                    for value in windows {
                        guard !session.isCancelled, !session.isUnresponsive, ContinuousClock.now < deadline else {
                            return .unverifiable(.scanTimedOut)
                        }
                        let window = SystemAXNode(value, session: session)
                        let token = "\(pid)/\(app.launchDate?.timeIntervalSince1970 ?? 0)/\(CFHash(value))"
                        if previous?.id == token { previousWindowExists = true }
                        inspect(window, token: token, client: client, context: context, pid: pid, bundleID: bundleID,
                                policy: policy, previous: previous, deadline: deadline, result: &observation)
                        if observation.denied { return .denied }
                    }
                    // A native client's dedicated call window vanished from its complete
                    // window list. Chrome can hide a live tab, so it needs a rejoin control.
                    if wasRecording && client != .googleMeet && !previousWindowExists {
                        observation.previousLeft = true
                    }
                }
            }
        }
        let discoveredAt = ContinuousClock.now
        guard !session.isCancelled, !session.isUnresponsive, discoveredAt < deadline else { return .unverifiable(.scanTimedOut) }
        if let verdict = MeetingScanVerdict.resolve(denied: observation.denied, issue: observation.issue,
                                                    candidates: observation.candidates.count,
                                                    previousProcessExists: observation.previousProcessExists,
                                                    previousLeft: observation.previousLeft) { return verdict }
        guard let call = observation.candidates.first else { return .left }
        let finalDeadline = finalDeadline(for: call.client, discoveredAt: discoveredAt, discoveryDeadline: deadline)
        let captionDeadline = min(deadline, discoveredAt + .milliseconds(100))
        let captions = call.captionRegions.flatMap { MeetingCaptionReader.read(region: $0, deadline: captionDeadline) }
        // Access to a tab, title or document can change during a tree walk.
        guard call.window.title == call.context.windowTitle else { return .unverifiable(.sourceChanged) }
        if let oldArea = call.webArea {
            let current = ChromeMeetingScan.inspect(call.window, deadline: finalDeadline)
            if let issue = current.issue { return .unverifiable(issue) }
            guard current.pageCount == 1 else { return .unverifiable(.chromePages) }
            guard let area = current.webArea, CFEqual(oldArea.element, area.element),
                  current.url == call.context.url else { return .unverifiable(.sourceChanged) }
            if current.privateProfile(title: call.context.windowTitle) { return .denied }
            guard current.regularProfile(title: call.context.windowTitle) else { return .unverifiable(.chromeProfile) }
        } else {
            let document = call.window.url(kAXDocumentAttribute)
            let filePath = document?.isFileURL == true ? document?.path(percentEncoded: false) : nil
            guard filePath == call.context.filePath, (filePath == nil ? document : nil) == call.context.url else {
                return .unverifiable(.sourceChanged)
            }
        }
        guard !session.isUnresponsive, !session.isCancelled, ContinuousClock.now < finalDeadline else { return .unverifiable(.scanTimedOut) }
        return .joined(VerifiedMeeting(id: call.id, client: call.client, pid: call.pid, bundleID: call.bundleID,
                                       context: call.context, micAllowed: call.micAllowed, captions: captions,
                                       windowToken: call.windowToken))
    }

    private static func inspect(_ window: SystemAXNode, token: String, client: MeetingClient, context: WindowContext,
                                pid: pid_t, bundleID: String, policy: CapturePolicy, previous: MeetingContinuity?,
                                deadline: ContinuousClock.Instant, result: inout Observation) {
        guard window.role == "AXWindow", let title = window.title else {
            if previous?.pid == pid { result.issue = .windowList(client) }
            return
        }
        var context = context
        context.windowTitle = title
        var webArea: SystemAXNode?
        var id = token
        if client == .googleMeet {
            let chrome = ChromeMeetingScan.inspect(window, deadline: deadline)
            if let issue = chrome.issue { result.issue = issue; return }
            context.url = chrome.url
            context.isPrivateBrowsing = chrome.privateProfile(title: title)
            guard policy.shouldCapture(context) else {
                if ChromeMeetingWindow.blocksExcludedWindow(token: token, pid: pid, url: chrome.url, previous: previous,
                    regularSinglePage: chrome.hasRegularSiblingProfile(title: title)) {
                    result.denied = true
                }
                return
            }
            guard let room = client.room(at: chrome.url), let area = chrome.webArea else { return }
            id = "\(pid)/meet/\(room.hashValue)"
            guard chrome.pageCount == 1 else { result.issue = .chromePages; return }
            guard chrome.regularProfile(title: title) else { result.issue = .chromeProfile; return }
            webArea = area
        } else {
            if let document = window.url(kAXDocumentAttribute) {
                if document.isFileURL { context.filePath = document.path(percentEncoded: false) }
                else { context.url = document }
            }
            guard policy.shouldCapture(context) else {
                if previous?.id == id { result.denied = true }
                return
            }
        }

        var reader = MeetingControlReader<SystemAXNode>(client: client, deadline: deadline)
        reader.read(webArea ?? window)
        guard reader.complete else { result.issue = .controls(client); return }
        if reader.controls.left, previous?.id == id { result.previousLeft = true }
        if reader.controls.joined {
            result.candidates.append(Candidate(id: id, client: client, pid: pid, bundleID: bundleID,
                                               context: context, window: window, windowToken: token, webArea: webArea,
                                               captionRegions: reader.captionRegions, micAllowed: reader.controls.micAllowed))
        }
    }

    /// Bundle identifiers are self-declared. Tie the PID used for AX and audio to the
    /// vendor's signed application before its controls can authorize recording.
    private static func trusted(pid: pid_t, client: MeetingClient, bundleID: String) -> Bool {
        let team = switch client {
        case .googleMeet: "EQHXZ8M8AV"
        case .zoom: "BJ4HAAB9B3"
        case .teams: "UBF8T346G9"
        }
        let rule = "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(team)\""
        var code: SecCode?
        var requirement: SecRequirement?
        return SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess
            && SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess
            && code.map { SecCodeCheckValidity($0, [], requirement) == errSecSuccess } == true
    }
}
