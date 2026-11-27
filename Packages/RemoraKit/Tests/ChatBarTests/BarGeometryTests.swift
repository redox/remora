import Testing
import Foundation
import CoreGraphics
@testable import ChatBar

private let mbp = ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
                             auxiliaryTopLeft: CGRect(x: 0, y: 944, width: 662, height: 38), auxiliaryTopRight: CGRect(x: 850, y: 944, width: 662, height: 38), safeAreaTop: 38)
private let external = ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055),
                                  auxiliaryTopLeft: nil, auxiliaryTopRight: nil, safeAreaTop: 0)

@Test func notchIsGapBetweenAuxiliaryAreas() { #expect(BarGeometry.notch(mbp) == CGRect(x: 662, y: 944, width: 188, height: 38)) }
@Test func noNotchWithoutBothAreas() {
    #expect(BarGeometry.notch(external) == nil)
    var half = mbp; half.auxiliaryTopRight = nil
    #expect(BarGeometry.notch(half) == nil)
}
@Test func topBarSitsUnderNotch() {
    #expect(BarGeometry.visibleBarRect(.top, mbp) == CGRect(x: 662, y: 938, width: 188, height: 6))
    #expect(BarGeometry.collapsedPanelFrame(.top, mbp) == CGRect(x: 662, y: 938, width: 188, height: 44))
}
@Test func noNotchFallsBackToTopCenter() {
    #expect(BarGeometry.visibleBarRect(.top, external) == CGRect(x: 860, y: 1049, width: 200, height: 6))
    #expect(BarGeometry.collapsedPanelFrame(.top, external) == CGRect(x: 860, y: 1049, width: 200, height: 31))
}
@Test func sideBottomAndCornerBars() {
    let v = mbp.visibleFrame
    #expect(BarGeometry.visibleBarRect(.left, mbp) == CGRect(x: 0, y: v.midY - 80, width: 6, height: 160))
    #expect(BarGeometry.visibleBarRect(.right, mbp) == CGRect(x: 1506, y: v.midY - 80, width: 6, height: 160))
    #expect(BarGeometry.visibleBarRect(.bottom, mbp) == CGRect(x: 656, y: 0, width: 200, height: 6))
    #expect(BarGeometry.visibleBarRect(.bottomLeft, mbp) == CGRect(x: 12, y: 0, width: 120, height: 6))
    #expect(BarGeometry.visibleBarRect(.bottomRight, mbp) == CGRect(x: 1380, y: 0, width: 120, height: 6))
}
@Test func expandedTopIsCentredOnNotch() {
    let f = BarGeometry.expandedFrame(.top, size: CGSize(width: 420, height: 520), mbp)
    #expect(f.midX == 756)
}

@Test func defaultChatUsesTheAvailableHeightBelowTheNotch() {
    var settings = BarSettings()
    settings.expandedSizes = ["top": CGSize(width: 600, height: 720), "left": CGSize(width: 420, height: 520)]
    #expect(BarGeometry.expandedFrame(.top, size: settings.savedExpandedSize, mbp).size == CGSize(width: 600, height: 720))

    settings.savedExpandedSize = nil
    let card = BarGeometry.expandedFrame(.top, size: settings.savedExpandedSize, mbp)
    #expect(card.size == CGSize(width: 900, height: 928))
    #expect(card.midX == mbp.frame.midX)
    #expect(card.maxY == mbp.frame.maxY - mbp.safeAreaTop - 8)
    #expect(BarGeometry.expandedFrame(.top, size: settings.savedExpandedSize, external).size == CGSize(width: 900, height: 960))
    settings.position = .left
    #expect(settings.savedExpandedSize == CGSize(width: 420, height: 520))
}

@Test func hiddenMenuBarNeverLetsTheChatCoverTheNotch() {
    var screen = mbp
    screen.visibleFrame = screen.frame
    let card = BarGeometry.expandedFrame(.top, size: CGSize(width: 420, height: 520), screen)
    #expect(card.maxY == screen.frame.maxY - screen.safeAreaTop - 8)
    #expect(!card.intersects(BarGeometry.notch(screen)!))
    let peek = BarLayout.panel(card: card, bar: BarGeometry.collapsedPanelFrame(.top, screen))
    #expect(peek.card.minY == screen.safeAreaTop + 8)
    #expect(peek.frame.contains(BarGeometry.collapsedPanelFrame(.top, screen)))
}

@Test func safeAreaProtectsTheHeaderWithoutAuxiliaryNotchAreas() {
    var screen = mbp
    screen.visibleFrame = screen.frame
    screen.auxiliaryTopLeft = nil
    screen.auxiliaryTopRight = nil
    let card = BarGeometry.expandedFrame(.top, size: CGSize(width: 420, height: 520), screen)
    #expect(card.maxY == 936)
}

@Test(arguments: BarPosition.allCases)
func oversizedCardsStayBelowTheNotchWithAHiddenMenuBar(_ position: BarPosition) {
    var screen = mbp
    screen.visibleFrame = screen.frame
    let card = BarGeometry.expandedFrame(position, size: CGSize(width: 5000, height: 5000), screen)
    #expect(card.maxY <= screen.frame.maxY - screen.safeAreaTop - 8)
    #expect(card.minY >= screen.visibleFrame.minY + 8)
    #expect(card.height == 928)
}

@Test func notchClearanceUsesTheDisplaysGlobalOrigin() {
    var screen = mbp
    screen.frame = screen.frame.offsetBy(dx: 1512, dy: 100)
    screen.visibleFrame = screen.frame
    screen.auxiliaryTopLeft = screen.auxiliaryTopLeft?.offsetBy(dx: 1512, dy: 100)
    screen.auxiliaryTopRight = screen.auxiliaryTopRight?.offsetBy(dx: 1512, dy: 100)
    let card = BarGeometry.expandedFrame(.top, size: CGSize(width: 420, height: 520), screen)
    #expect(card.midX == screen.frame.midX)
    #expect(card.maxY == 1036)
}
@Test(arguments: BarPosition.allCases) func expandedStaysOnScreen(_ p: BarPosition) {
    for s in [mbp, external] {
        #expect(s.visibleFrame.insetBy(dx: 8, dy: 8).contains(BarGeometry.expandedFrame(p, size: CGSize(width: 420, height: 520), s)))
    }
}
@Test func clampsHugeSize() { #expect(BarGeometry.clampSize(CGSize(width: 5000, height: 5000), mbp) == CGSize(width: 1496, height: 928)) }
@Test func positionTitles() {
    #expect(BarPosition.top.title == "Top (under the notch)")
    #expect(BarPosition.bottomRight.rawValue == "bottom_right")
}
@Test func settingsClampTextScaleAndDecodeOldJSON() throws {
    let a = try JSONDecoder().decode(BarSettings.self, from: Data(#"{"textScale":2}"#.utf8))
    #expect(a.textScale == 1.5)
    let b = try JSONDecoder().decode(BarSettings.self, from: Data("{}".utf8))
    #expect(b.position == .top && b.openOnHover && !b.autoHide && !b.dimWhenUnfocused && !b.pinned && b.textScale == 1.0)
    var c = BarSettings(); c.textScale = 0.2
    #expect(c.textScale == 1.0)
}

@Test func exactExpandedFramesForSidesAndBottom() {
    let size = CGSize(width: 420, height: 520)
    #expect(BarGeometry.expandedFrame(.left, size: size, mbp) == CGRect(x: 8, y: 212, width: 420, height: 520))
    #expect(BarGeometry.expandedFrame(.right, size: size, mbp) == CGRect(x: 1084, y: 212, width: 420, height: 520))
    #expect(BarGeometry.expandedFrame(.bottom, size: size, mbp) == CGRect(x: 546, y: 8, width: 420, height: 520))
}
@Test func secondDisplayWithNonZeroOrigin() {
    let second = ScreenInfo(frame: CGRect(x: 1512, y: 100, width: 1920, height: 1080), visibleFrame: CGRect(x: 1512, y: 100, width: 1920, height: 1055),
                            auxiliaryTopLeft: nil, auxiliaryTopRight: nil, safeAreaTop: 0)
    #expect(BarGeometry.visibleBarRect(.top, second) == CGRect(x: 2372, y: 1149, width: 200, height: 6))
    #expect(BarGeometry.visibleBarRect(.bottomRight, second) == CGRect(x: 3300, y: 100, width: 120, height: 6))
    #expect(BarGeometry.visibleBarRect(.left, second) == CGRect(x: 1512, y: 627.5 - 80, width: 6, height: 160))
    for p in BarPosition.allCases {
        #expect(second.visibleFrame.insetBy(dx: 8, dy: 8).contains(BarGeometry.expandedFrame(p, size: CGSize(width: 420, height: 520), second)))
    }
    #expect(BarGeometry.expandedFrame(.bottomLeft, size: CGSize(width: 420, height: 520), second) == CGRect(x: 1520, y: 108, width: 420, height: 520))
}
@Test func settingsRoundTrip() throws {
    var s = BarSettings()
    s.position = .bottomRight; s.openOnHover = false; s.autoHide = true; s.dimWhenUnfocused = true
    s.textScale = 1.3; s.pinned = true; s.expandedSizes = ["top": CGSize(width: 500, height: 600)]
    let back = try JSONDecoder().decode(BarSettings.self, from: JSONEncoder().encode(s))
    #expect(back == s)
}
