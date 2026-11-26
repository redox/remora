import Accessibility
import ApplicationServices
import Foundation

struct ChromeControlIdentity {
    let role: String?
    let id: String?
    let classes: [String]

    /// These native Chrome views contain selectors. Document panes and the profile
    /// controls are siblings. Never use a page title or a button label to prune a branch.
    var isSelectorContainer: Bool {
        if classes.contains("BookmarkBarView") || classes.contains("TabStrip") { return true }
        return (role == "AXTabGroup" || role == "AXGroup") && id == "view_21"
    }
}

protocol WindowAXElement: AXNode {
    var chromeIdentity: ChromeControlIdentity { get }
    var nativeClasses: [String] { get }
    var chromeButtonLabels: [String] { get }
    func verificationChildren(upTo limit: Int) -> [Self]?
    var controlReadable: Bool { get }
    var controlEnabled: Bool { get }
    var domIdentifier: String? { get }
    var help: String? { get }
    var customDescriptions: [String] { get }
    var pageURL: URL? { get }
}

extension SystemAXNode: WindowAXElement {
    var chromeIdentity: ChromeControlIdentity {
        let fields = session.copyAttributes(element, [kAXRoleAttribute, "AXDOMIdentifier", "AXDOMClassList"])
        return ChromeControlIdentity(role: fields?[0] as? String, id: fields?[1] as? String,
                                     classes: fields?[2] as? [String] ?? [])
    }

    var nativeClasses: [String] { session.copyAttribute(element, "AXDOMClassList") as? [String] ?? [] }

    var chromeButtonLabels: [String] {
        session.copyAttributes(element, [kAXTitleAttribute, kAXDescriptionAttribute])?.compactMap { $0 as? String } ?? []
    }

    func verificationChildren(upTo limit: Int) -> [Self]? {
        session.copyElements(element, kAXChildrenAttribute, max: limit, emptyIfUnsupported: true)?
            .map { SystemAXNode($0, session: session) }
    }

    var controlReadable: Bool { !session.isCancelled && !session.isUnresponsive }
    var controlEnabled: Bool { bool(kAXEnabledAttribute) == true }
    var domIdentifier: String? { string("AXDOMIdentifier") }
    var help: String? { string(kAXHelpAttribute) }
    var customDescriptions: [String] {
        guard let data = session.copyAttribute(element, "AXCustomContent") as? Data else { return [] }
        return Self.customDescriptions(from: data)
    }

    /// Across Accessibility IPC, macOS archives the custom content array. Chrome uses its
    /// "description" entry for toolbar explanations that VoiceOver announces separately.
    static func customDescriptions(from data: Data) -> [String] {
        guard !data.isEmpty, data.count <= 32_768,
              let items = (try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSArray.self, AXCustomContent.self],
                                                                    from: data)) as? [AXCustomContent] else { return [] }
        return items.filter { $0.label == "description" }.map(\.value)
    }

    var pageURL: URL? { url(kAXURLAttribute) }
}

/// Reads actionable controls only. Static text, meeting chat, participant lists, input
/// fields and embedded frames cannot supply call evidence or the local microphone state.
struct MeetingControlReader<Node: WindowAXElement> {
    let client: MeetingClient
    let deadline: ContinuousClock.Instant
    private(set) var controls = MeetingControls()
    private(set) var captionRegions: [Node] = []
    private(set) var complete = true

    mutating func read(_ root: Node) {
        var pending = [(node: root, depth: 0, inToolbar: false, inPage: false)]
        var visited = 0
        while let (node, depth, inToolbar, inPage) = pending.popLast() {
            visited += 1
            guard visited <= 900, depth <= 32, ContinuousClock.now < deadline,
                  node.controlReadable else {
                complete = false
                return
            }
            guard let role = node.role else { complete = false; return }
            if role == "AXWindow" || role == "AXHeading" {
                if let label = node.title ?? node.nodeDescription { controls.observePrejoinLabel(label) }
            }
            // Chromium can expose a pressed media button as a checkbox or switch.
            // Only a button can authorize the separate leave-call action.
            let mediaToggle = client == .googleMeet && ["AXCheckBox", "AXSwitch", "AXToggleButton"].contains(role)
            if mediaToggle || role == "AXButton" || role == "AXPopUpButton" || role == "AXMenuButton" {
                let id = client == .teams ? node.domIdentifier : nil
                let labels = [node.title, node.nodeDescription].compactMap { $0 }
                for label in labels { controls.observePrejoinLabel(label) }
                guard node.controlEnabled else { continue }
                for label in labels {
                    if isOwnControl(label: label, id: id, inToolbar: inToolbar) {
                        controls.observe(button: label, client: client, mediaToggle: mediaToggle)
                    }
                }
                continue
            }
            var page = inPage
            if role == "AXWebArea" {
                // Zoom's meeting controls are native; its embedded web content is unrelated.
                if inPage || client == .zoom { continue }
                if client == .teams {
                    guard let url = node.pageURL, url.scheme == "https",
                          ["teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft"].contains(url.host()) else { continue }
                }
                page = true
            }
            if MeetingCaptionReader.isRegion(node) {
                if captionRegions.count < 2 { captionRegions.append(node) }
                continue
            }
            guard ["AXWebArea", "AXWindow", "AXGroup", "AXSplitGroup", "AXToolbar", "AXScrollArea",
                   "AXTabGroup", "AXLayoutArea", "AXUnknown", "AXDialog", "AXSheet", "AXPopover"].contains(role) else { continue }
            let toolbar = inToolbar || role == "AXToolbar" || isCallToolbar(node)
            guard let kids = node.verificationChildren(upTo: 97), kids.count <= 96 else { complete = false; return }
            for child in kids.reversed() {
                pending.append((child, depth + 1, toolbar, page))
            }
        }
    }

    private func isCallToolbar(_ node: Node) -> Bool {
        guard node.role == "AXGroup" else { return false }
        let names = ["call controls", "meeting controls", "meeting toolbar", "commandes d’appel",
                     "commandes d'appel", "commandes de la reunion"]
        return [node.title, node.nodeDescription].compactMap { $0 }.contains { names.contains(BrowserCatalog.fold($0)) }
    }

    private func isOwnControl(label: String, id: String?, inToolbar: Bool) -> Bool {
        if client == .googleMeet || inToolbar { return true }
        if client == .teams {
            // Teams places these IDs on its call buttons in the desktop webview.
            return ["hangup-button", "microphone-button", "camera-button", "call-hangup", "call-mute",
                    "call-unmute", "call-video", "rejoin-button"].contains(id)
        }
        // A bare "Mute" in Zoom's participants panel belongs to somebody else. Only
        // its native meeting toolbar may supply that short control label.
        let audioActions = ["mute", "unmute", "mute audio", "unmute audio", "couper le son", "retablir le son",
                            "desactiver le son", "reactiver le son"]
        let action = BrowserCatalog.fold(label).components(separatedBy: " (").first ?? ""
        return !audioActions.contains(action)
    }
}
