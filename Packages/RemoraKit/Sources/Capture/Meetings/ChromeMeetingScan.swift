import Foundation

/// Meeting verification needs a complete inventory of document panes and native profile controls.
struct ChromeMeetingScan<Node: WindowAXElement> {
    private(set) var issue: MeetingVerificationIssue?
    var complete: Bool { issue == nil }
    private(set) var pageCount = 0
    private(set) var webArea: Node?
    private(set) var url: URL?
    private(set) var avatar: String?
    private(set) var knownToolbar = false
    private var chromeLabels: [String] = []

    static func inspect(_ window: Node, deadline: ContinuousClock.Instant) -> Self {
        var scan = Self()
        var queue = [window]
        var index = 0
        while index < queue.count {
            guard ContinuousClock.now < deadline else { scan.issue = .scanTimedOut; break }
            let node = queue[index]
            index += 1
            var identity = node.chromeIdentity
            if identity.role == nil, node.controlReadable {
                // The role is required even when Chrome cannot supply the optional DOM metadata in a batch.
                identity = ChromeControlIdentity(role: node.role, id: node.domIdentifier, classes: node.nativeClasses)
            }
            guard let role = identity.role else { scan.issue = .chromeRole; break }
            if role == "AXWebArea" {
                scan.pageCount += 1
                let url = node.pageURL
                // A Meet pane in either position must bring a split window to the ambiguity check.
                if scan.webArea == nil || MeetingClient.googleMeet.room(at: url) != nil {
                    scan.webArea = node
                    scan.url = url
                }
                continue
            }
            if identity.isSelectorContainer { continue }
            switch role {
            case "AXButton", "AXMenuButton", "AXPopUpButton":
                let labels = node.chromeButtonLabels
                scan.chromeLabels += labels
                scan.observeChromeButton(node, identity: identity, labels: labels)
            case "AXStaticText", "AXImage":
                scan.chromeLabels += node.chromeButtonLabels
            default: break
            }
            let remaining = FrontmostWindowReader.webAreaSearchNodes - queue.count
            guard let children = node.verificationChildren(upTo: remaining + 1) else {
                scan.issue = .chromeChildren
                break
            }
            guard children.count <= remaining else { scan.issue = .chromeWindowSize; break }
            queue += children
        }
        return scan
    }

    private mutating func observeChromeButton(_ button: Node, identity: ChromeControlIdentity, labels: [String]) {
        // Only callers above the first web area can provide native Views class names.
        if identity.id == "view_1018" || identity.classes.contains("AvatarToolbarButton") {
            let descriptions = [button.help].compactMap { $0 } + button.customDescriptions
            if let marker = (labels + descriptions).first(where: ChromeMeetingWindow.privateAvatar) {
                avatar = marker
            } else if avatar == nil {
                avatar = labels.first { !$0.isEmpty }
            }
        } else if identity.id == "view_1007" || identity.classes.contains("BrowserAppMenuButton") {
            knownToolbar = knownToolbar || labels.contains(where: ChromeMeetingWindow.isAppMenuLabel)
                || button.help.map(ChromeMeetingWindow.isAppMenuLabel) == true
                || button.customDescriptions.contains(where: ChromeMeetingWindow.isAppMenuLabel)
        }
    }
}

extension ChromeMeetingScan {
    func privateProfile(title: String?) -> Bool {
        ChromeMeetingWindow.privateAvatar(avatar)
            || BrowserCatalog.looksPrivate(bundleID: "com.google.Chrome", windowTitle: title, chromeLabels: chromeLabels)
    }

    /// An excluded sibling can be ruled out using native controls without reading its page title.
    func hasRegularSiblingProfile(title: String?) -> Bool {
        pageCount == 1 && !privateProfile(title: title)
            && ChromeMeetingWindow.regular(title: title, pageTitle: nil, avatar: avatar, knownToolbar: knownToolbar)
    }

    func regularProfile(title: String?) -> Bool {
        ChromeMeetingWindow.regular(title: title, pageTitle: webArea?.title, avatar: avatar, knownToolbar: knownToolbar)
    }
}
