import CoreGraphics
import Testing
@testable import Indicator

private func w(_ id: String?, _ layer: Int) -> OnScreenWindow {
    OnScreenWindow(ownerBundleID: id, layer: layer, bounds: CGRect(x: 0, y: 0, width: 300, height: 200), alpha: 1)
}

@Test func zoomShareToolbarDetected() { #expect(ScreenShareHeuristic.isLikelySharing([w("us.zoom.xos", 3)])) }
@Test func statusItemsAloneAreNotSharing() {
    #expect(!ScreenShareHeuristic.isLikelySharing([w("us.zoom.xos", 25), w("com.loom.desktop", 25), w("pl.maketheweb.cleanshotx", 25)]))
}
@Test func normalWindowsAreNotSharing() {
    #expect(!ScreenShareHeuristic.isLikelySharing([w("us.zoom.xos", 0), w("com.microsoft.teams2", 0)]))
}
@Test func screenRecordingStopButtonDetected() {
    #expect(ScreenShareHeuristic.isLikelySharing([w("com.apple.screencaptureui", 25)]))
}
@Test func unknownOwnersIgnored() {
    #expect(!ScreenShareHeuristic.isLikelySharing([w("com.example.app", 3), w(nil, 3)]))
}

@Test func invisibleOrTinyHelperWindowsAreFilteredOut() {
    #expect(OnScreenWindow.isMeaningful(bounds: CGRect(x: 0, y: 0, width: 300, height: 200), alpha: 1))
    #expect(OnScreenWindow.isMeaningful(bounds: CGRect(x: 0, y: 0, width: 40, height: 40), alpha: 0.5))
    #expect(!OnScreenWindow.isMeaningful(bounds: CGRect(x: 0, y: 0, width: 300, height: 200), alpha: 0))
    #expect(!OnScreenWindow.isMeaningful(bounds: CGRect(x: 0, y: 0, width: 39, height: 200), alpha: 1))
    #expect(!OnScreenWindow.isMeaningful(bounds: CGRect(x: 0, y: 0, width: 300, height: 1), alpha: 1))
    #expect(!OnScreenWindow.isMeaningful(bounds: .zero, alpha: 1))
}

@Test func recordingStopButtonIsSmallButStillDetected() {
    let stop = OnScreenWindow(ownerBundleID: "com.apple.screencaptureui", layer: 25,
                              bounds: CGRect(x: 0, y: 0, width: 24, height: 22), alpha: 1)
    #expect(ScreenShareHeuristic.isLikelySharing([stop]))
}

@Test func invisibleSlackHelperIsNotSharing() {
    let helper = OnScreenWindow(ownerBundleID: "com.tinyspeck.slackmacgap", layer: 3,
                                bounds: CGRect(x: 0, y: 0, width: 10, height: 10), alpha: 0)
    #expect(!ScreenShareHeuristic.isLikelySharing([helper]))
}
