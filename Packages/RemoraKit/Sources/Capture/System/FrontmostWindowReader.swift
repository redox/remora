import AppKit
import ApplicationServices

public enum AXReadError: Error, Sendable {
    /// An AX call hit the messaging timeout mid-read: the target app is hung or too slow.
    case appNotResponding
}

/// Reads the frontmost app's focused window through the Accessibility API.
///
/// Threading: synchronous AX IPC can block a thread for up to the messaging timeout per call,
/// so every read runs on one dedicated serial dispatch queue (never the Swift cooperative
/// pool), bridged back with a checked continuation. Cancelling the calling task (the engine
/// does so when it times a read out) flags the read's session, which short-circuits all
/// remaining AX calls so an abandoned read ends quickly.
public struct FrontmostWindowReader: WindowReading {
    static var queue: DispatchQueue { AXQueue.queue }

    /// Bounds for locating the web area under a browser window (browser chrome only; the
    /// page itself is never descended into during this search).
    static let webAreaSearchDepth = 12
    static let webAreaSearchNodes = 400

    private let extractor: AXTextExtractor
    private let ownBundleID: String?
    /// Diagnostics only: lets a probe read an app without flipping its accessibility flags.
    private let enablesAppAccessibility: Bool

    public init(extractor: AXTextExtractor = .init()) {
        self.init(extractor: extractor, enablesAppAccessibility: true)
    }

    init(extractor: AXTextExtractor, enablesAppAccessibility: Bool) {
        self.extractor = extractor
        self.ownBundleID = Bundle.main.bundleIdentifier
        self.enablesAppAccessibility = enablesAppAccessibility
    }

    /// Full read: context plus extracted text. `nil` when there is no frontmost app, it is
    /// Remora itself, or it has no focused window (or is too unresponsive to say).
    public func readFrontmost() async throws -> (context: WindowContext, text: String)? {
        try await readFrontmost(policy: CapturePolicy(userRules: []))
    }

    /// Full read where the tree is walked only if `policy` (built-in skips plus the user's
    /// exclusions) allows the context.
    public func readFrontmost(policy: CapturePolicy) async throws -> (context: WindowContext, text: String)? {
        try await onAXQueue { session in
            guard let target = frontmostTarget() else { return nil }
            return try read(target, policy: policy, session)
        }
    }

    /// Diagnostics: the same read for any running app, frontmost or not.
    func read(application app: NSRunningApplication) async throws
        -> (context: WindowContext, text: String)? {
        let target = Target(app)
        return try await onAXQueue { session in
            try read(target, policy: CapturePolicy(userRules: []), session)
        }
    }

    /// A context plus the identity used to check that it did not change between clipboard
    /// polls (see `ClipboardAttribution`).
    public struct ContextSample: Sendable {
        public var context: WindowContext
        public var identity: ContextIdentity
    }

    /// Cheap read for clipboard attribution: app, window title, URL and private-window flag,
    /// without extracting any text. Apps without a focused window get an app-only context.
    /// `nil` when there is no frontmost app, it is Remora, or the app is not responding
    /// (callers should then drop the clipboard text: exclusions cannot be evaluated).
    public func readContext() async -> ContextSample? {
        let sample = try? await onAXQueue { session -> ContextSample? in
            guard let target = frontmostTarget() else { return nil }
            let resolved = resolve(target, session)
            let context = resolved?.context
                ?? WindowContext(app: target.name, bundleID: target.bundleID)
            guard !session.isUnresponsive, !session.isCancelled else { return nil }
            return ContextSample(context: context, identity: ContextIdentity(
                pid: target.pid, window: resolved.map { Int(bitPattern: CFHash($0.window.element)) },
                windowTitle: context.windowTitle, url: context.url,
                isPrivateBrowsing: context.isPrivateBrowsing))
        }
        return sample ?? nil
    }

    /// Geometry of the frontmost app's focused window (position, size, full-screen flag,
    /// subrole only; never walks children). `nil` for Remora, no focused window, an
    /// unresponsive app or a cancelled read. Runs on the AX queue.
    public func readFocusedWindowGeometry() async -> WindowGeometry? {
        let geometry = try? await onAXQueue { session -> WindowGeometry? in
            guard let target = frontmostTarget() else { return nil }
            let app = SystemAXNode(AXUIElementCreateApplication(target.pid), session: session)
            guard let window = app.element(kAXFocusedWindowAttribute),
                  let origin = window.point(kAXPositionAttribute),
                  let size = window.size(kAXSizeAttribute) else { return nil }
            let fullScreen = window.bool("AXFullScreen") ?? false
            let standard = window.subrole == kAXStandardWindowSubrole
            guard !session.isUnresponsive, !session.isCancelled else { return nil }
            return WindowGeometry(
                pid: target.pid, window: Int(bitPattern: CFHash(window.element)),
                frame: CGRect(origin: origin, size: size),
                isFullScreen: fullScreen, isStandardWindow: standard)
        }
        return geometry ?? nil
    }

    // MARK: - Queue bridge

    private func onAXQueue<T: Sendable>(
        _ work: @escaping @Sendable (AXReadSession) throws -> T
    ) async throws -> T {
        try await AXQueue.run(work)
    }

    // MARK: - Reading (AX queue only)

    private struct Target: Sendable {
        let pid: pid_t
        let name: String
        let bundleID: String?
        let bundleURL: URL?
        let launchDate: Date?

        init(_ app: NSRunningApplication) {
            pid = app.processIdentifier
            bundleID = app.bundleIdentifier
            let localized = app.localizedName.map(AppName.normalize) ?? ""
            name = localized.isEmpty ? (app.bundleIdentifier ?? "Unknown") : localized
            bundleURL = app.bundleURL
            launchDate = app.launchDate
        }
    }

    private func frontmostTarget() -> Target? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        if let id = app.bundleIdentifier, id == ownBundleID { return nil }
        return Target(app)
    }

    private func read(_ target: Target, policy: CapturePolicy, _ session: AXReadSession) throws
        -> (context: WindowContext, text: String)? {
        guard let (context, textRoot, _) = resolve(target, session) else { return nil }
        // Built-in skips, private windows and user exclusions are rejected by the engine
        // anyway; not walking their tree means their content never even crosses into this
        // process.
        let text = policy.shouldCapture(context)
            ? textRoot.map(extractor.extract(from:)) ?? ""
            : ""
        if session.isCancelled { return nil }
        if session.isUnresponsive { throw AXReadError.appNotResponding }
        return (context, text)
    }

    /// Focused window context and the node whose text should be extracted (the web area for
    /// browsers, the window otherwise). `nil` when the app has no focused window.
    private func resolve(_ target: Target, _ session: AXReadSession)
        -> (context: WindowContext, textRoot: SystemAXNode?, window: SystemAXNode)? {
        let app = SystemAXNode(AXUIElementCreateApplication(target.pid), session: session)
        if enablesAppAccessibility {
            AppAccessibility.enable(pid: target.pid, bundleID: target.bundleID, bundleURL: target.bundleURL,
                                    launchDate: target.launchDate, session: session)
        }
        guard let window = app.element(kAXFocusedWindowAttribute) else { return nil }

        var context = WindowContext(app: target.name, bundleID: target.bundleID,
                                    windowTitle: window.string(kAXTitleAttribute))
        guard BrowserCatalog.isBrowser(target.bundleID) else {
            applyDocument(window.url(kAXDocumentAttribute), to: &context)
            return (context, window, window)
        }

        let scan = scanBrowserWindow(window)
        context.url = scan.url
        context.isPrivateBrowsing = BrowserCatalog.looksPrivate(
            bundleID: target.bundleID, windowTitle: context.windowTitle,
            chromeLabels: scan.chromeLabels)
        if BrowserCatalog.usesSafariPrivateTitle(target.bundleID),
           SafariPrivateTitle.system.isPrivate(title: context.windowTitle) {
            context.isPrivateBrowsing = true
        }
        return (context, scan.webArea, window)
    }

    private func applyDocument(_ document: URL?, to context: inout WindowContext) {
        guard let document else { return }
        if document.isFileURL {
            context.filePath = document.path(percentEncoded: false)
        } else if let scheme = document.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            context.url = document
        }
    }

    private struct BrowserScan {
        var webArea: SystemAXNode?
        var url: URL?
        var chromeLabels: [String] = []
    }

    private static let labelRoles: Set<String> = [
        "AXButton", "AXMenuButton", "AXPopUpButton", "AXStaticText", "AXImage",
    ]

    /// Breadth-first walk of the browser chrome (bounded), collecting web areas without
    /// descending into them, plus labels of chrome controls for private-window heuristics.
    /// The page's web area is the first one with a web/file URL (skipping DevTools, side
    /// panels on internal pages, etc.), else the first one found.
    private func scanBrowserWindow(_ window: SystemAXNode) -> BrowserScan {
        var scan = BrowserScan()
        var webAreas: [(node: SystemAXNode, url: URL?)] = []
        var queue: [(node: SystemAXNode, depth: Int)] = [(window, 0)]
        var index = 0
        while index < queue.count, index < Self.webAreaSearchNodes {
            let (node, depth) = queue[index]
            index += 1
            let role = node.role
            if role == "AXWebArea" {
                webAreas.append((node, node.url(kAXURLAttribute)))
                continue
            }
            if let role, Self.labelRoles.contains(role) {
                scan.chromeLabels += [node.title, node.nodeDescription].compactMap { $0 }
            }
            if depth < Self.webAreaSearchDepth {
                queue += node.childNodes.map { ($0, depth + 1) }
            }
        }
        let page = webAreas.first { area in
            guard let scheme = area.url?.scheme?.lowercased() else { return false }
            return ["http", "https", "file"].contains(scheme)
        } ?? webAreas.first
        scan.webArea = page?.node
        scan.url = page?.url
        return scan
    }
}
