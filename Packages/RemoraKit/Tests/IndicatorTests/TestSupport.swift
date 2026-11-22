import Foundation
@testable import Capture
@testable import Indicator

func ctx(
    app: String = "Safari",
    bundleID: String? = nil,
    title: String? = nil,
    url: String? = nil,
    path: String? = nil,
    privateBrowsing: Bool = false
) -> WindowContext {
    WindowContext(
        app: app, bundleID: bundleID, windowTitle: title,
        url: url.flatMap { URL(string: $0) }, filePath: path,
        isPrivateBrowsing: privateBrowsing)
}

func front(_ name: String, pid: Int32, bundleID: String? = nil,
           verdict: CaptureVerdict? = .allowed) -> FrontmostApp {
    FrontmostApp(pid: pid, name: name, bundleID: bundleID, appVerdict: verdict)
}

func seen(_ context: WindowContext, pid: Int32, window: Int?, verdict: CaptureVerdict) -> ObservedWindow {
    ObservedWindow(
        context: context,
        identity: ContextIdentity(pid: pid, window: window, windowTitle: context.windowTitle,
                                  url: context.url, isPrivateBrowsing: context.isPrivateBrowsing),
        verdict: verdict)
}

func s(_ status: IndicatorStatus, _ name: String, pid: Int32, window: Int? = nil,
       site: String? = nil) -> IndicatorState {
    IndicatorState(status: status, appName: name, site: site, pid: pid, window: window)
}

func input(paused: Bool = false, ax: Bool = true, _ f: FrontmostApp?, _ o: ObservedWindow?) -> IndicatorInput {
    IndicatorInput(accessibilityGranted: ax, isPaused: paused, frontmost: f, observed: o)
}
