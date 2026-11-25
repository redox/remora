import CoreGraphics
@testable import Capture
import Testing
@testable import Indicator

@Test func axToCocoaOnPrimary() {
    #expect(WindowBadge.cocoaFrame(ofAXFrame: .init(x: 100, y: 50, width: 800, height: 600), primaryScreenHeight: 1000)
            == CGRect(x: 100, y: 350, width: 800, height: 600))
}
@Test func axToCocoaSecondaryAbove() {
    #expect(WindowBadge.cocoaFrame(ofAXFrame: .init(x: 0, y: -900, width: 1440, height: 900), primaryScreenHeight: 1000)
            == CGRect(x: 0, y: 1000, width: 1440, height: 900))
}
@Test func axToCocoaSecondaryLeft() {
    #expect(WindowBadge.cocoaFrame(ofAXFrame: .init(x: -1920, y: 100, width: 800, height: 600), primaryScreenHeight: 1000)
            == CGRect(x: -1920, y: 300, width: 800, height: 600))
}
@Test func panelAtTopRight() {
    #expect(WindowBadge.panelFrame(forWindow: .init(x: 100, y: 350, width: 800, height: 600))
            == CGRect(x: 876, y: 928, width: 16, height: 16))
}

enum BadgeFlip: CaseIterable {
    case disabled, fullScreen, notStandard, tooSmall, interacting, sharing, otherPID, otherWindow,
         coversScreen, offScreen, noGeometry
}

extension BadgeConditions {
    static let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    static let baseline = BadgeConditions(
        enabled: true,
        state: s(.capturing, "Notes", pid: 1, window: 7),
        geometry: WindowGeometry(pid: 1, window: 7, frame: .init(x: 100, y: 50, width: 800, height: 600),
                                 isFullScreen: false, isStandardWindow: true),
        isInteracting: false, sharingDetected: false,
        primaryScreenHeight: 982, screenFrames: [screen])

    func flipped(_ flip: BadgeFlip) -> BadgeConditions {
        var c = self
        switch flip {
        case .disabled: c.enabled = false
        case .fullScreen: c.geometry?.isFullScreen = true
        case .notStandard: c.geometry?.isStandardWindow = false
        case .tooSmall: c.geometry?.frame.size = .init(width: 239, height: 600)
        case .interacting: c.isInteracting = true
        case .sharing: c.sharingDetected = true
        case .otherPID: c.geometry?.pid = 2
        case .otherWindow: c.geometry?.window = 8
        case .coversScreen: c.geometry?.frame = .init(x: 0, y: 0, width: 1512, height: 982)
        case .offScreen: c.geometry?.frame = .init(x: 1400, y: 50, width: 800, height: 600)
        case .noGeometry: c.geometry = nil
        }
        return c
    }
}

@Test func badgeShownInBaseline() { #expect(WindowBadge.shouldShow(.baseline)) }

@Test(arguments: BadgeFlip.allCases)
func badgeHiddenWhen(_ flip: BadgeFlip) {
    #expect(!WindowBadge.shouldShow(BadgeConditions.baseline.flipped(flip)))
}

@Test(arguments: [IndicatorStatus.pending, .unknown, .noAccessibility])
func badgeHiddenForTransientStatus(_ status: IndicatorStatus) {
    var c = BadgeConditions.baseline
    c.state.status = status
    #expect(!WindowBadge.shouldShow(c))
}

@Test func badgeShownWhenStateWindowUnknown() {
    var c = BadgeConditions.baseline
    c.state.window = nil
    #expect(WindowBadge.shouldShow(c))
}
