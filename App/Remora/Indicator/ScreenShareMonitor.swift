import AppKit
import CoreGraphics
import Indicator

/// Polls window metadata every 3 s and reports whether a screen share or recording looks active.
///
/// Metadata only (owner pid, layer, bounds, alpha): never `kCGWindowName`, never an image, so no
/// Screen Recording permission. Idle invisible helper windows are filtered by
/// `ScreenShareHeuristic`. Limits are those of `ScreenShareHeuristic`.
@MainActor
final class ScreenShareMonitor {
    private static let interval: TimeInterval = 3
    nonisolated private static let queue = DispatchQueue(label: "dev.remora.windowlist", qos: .utility)

    var onChange: @MainActor (Bool) -> Void = { _ in }
    private(set) var isSharing = false

    private var timer: Timer?
    private var generation = 0
    private var inFlight = false

    func start() {
        guard timer == nil else { return }
        generation += 1
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        generation += 1
        inFlight = false
        isSharing = false
    }

    private func poll() {
        guard !inFlight else { return }
        inFlight = true
        let mine = generation
        Task { [weak self] in
            let windows = await withCheckedContinuation { (c: CheckedContinuation<[OnScreenWindow], Never>) in
                Self.queue.async { c.resume(returning: Self.readWindows()) }
            }
            self?.finished(windows, generation: mine)
        }
    }

    private func finished(_ windows: [OnScreenWindow], generation mine: Int) {
        guard mine == generation else { return }
        inFlight = false
        let sharing = ScreenShareHeuristic.isLikelySharing(windows)
        guard sharing != isSharing else { return }
        isSharing = sharing
        onChange(sharing)
    }

    /// One run of the heuristic, off the main thread: for callers (the nudge gate) that need an
    /// answer while the badge's polling is off.
    nonisolated static func isSharingNow() async -> Bool {
        let windows = await withCheckedContinuation { (c: CheckedContinuation<[OnScreenWindow], Never>) in
            queue.async { c.resume(returning: readWindows()) }
        }
        return ScreenShareHeuristic.isLikelySharing(windows)
    }

    nonisolated private static func readWindows() -> [OnScreenWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var bundleIDs: [pid_t: String?] = [:]
        var out: [OnScreenWindow] = []
        for entry in list {
            guard let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            let bundleID: String?
            if let cached = bundleIDs[pid] {
                bundleID = cached
            } else {
                bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                bundleIDs[pid] = bundleID
            }
            out.append(OnScreenWindow(ownerBundleID: bundleID, layer: layer, bounds: bounds, alpha: alpha))
        }
        return out
    }
}
