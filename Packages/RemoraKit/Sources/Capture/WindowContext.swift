import Foundation

public struct WindowContext: Sendable, Equatable {
    public var app: String
    public var bundleID: String?
    public var windowTitle: String?
    public var url: URL?
    public var filePath: String?
    public var isPrivateBrowsing: Bool

    public init(app: String, bundleID: String? = nil, windowTitle: String? = nil,
                url: URL? = nil, filePath: String? = nil, isPrivateBrowsing: Bool = false) {
        self.app = AppName.normalize(app)
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.url = url
        self.filePath = filePath
        self.isPrivateBrowsing = isPrivateBrowsing
    }

    public var domain: String? {
        guard var host = url?.host()?.lowercased() else { return nil }
        while host.hasSuffix(".") { host.removeLast() }  // "paypal.com." is paypal.com
        return host.isEmpty ? nil : host
    }
}
