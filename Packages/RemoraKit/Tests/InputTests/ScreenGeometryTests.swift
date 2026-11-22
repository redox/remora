import CoreGraphics
import Testing
@testable import Input

@Test func axToCocoaFlip() {
    #expect(ScreenGeometry.cocoaRect(fromAX: CGRect(x: 10, y: 100, width: 5, height: 20), primaryScreenHeight: 1000) == CGRect(x: 10, y: 880, width: 5, height: 20))
}
