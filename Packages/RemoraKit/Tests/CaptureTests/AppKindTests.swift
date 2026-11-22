import Foundation
import Testing
@testable import Capture

@Test func browsersAreWebBacked() {
    #expect(AppKind.isWebBacked(bundleID: "com.google.Chrome", bundleURL: nil))
    #expect(AppKind.isWebBacked(bundleID: "com.apple.Safari", bundleURL: nil))
    #expect(!AppKind.isWebBacked(bundleID: "com.apple.TextEdit", bundleURL: nil))
    #expect(!AppKind.isWebBacked(bundleID: nil, bundleURL: nil))
}

@Test func electronBundlesAreWebBacked() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "appkind-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let electron = root.appending(path: "Slack.app")
    try FileManager.default.createDirectory(
        at: electron.appending(path: "Contents/Frameworks/Electron Framework.framework"), withIntermediateDirectories: true)
    let native = root.appending(path: "Notes.app")
    try FileManager.default.createDirectory(at: native.appending(path: "Contents/Frameworks"), withIntermediateDirectories: true)
    #expect(AppKind.isElectron(bundleURL: electron))
    #expect(AppKind.isWebBacked(bundleID: "com.tinyspeck.slackmacgap", bundleURL: electron))
    #expect(!AppKind.isElectron(bundleURL: native))
    #expect(!AppKind.isWebBacked(bundleID: "com.apple.Notes", bundleURL: native))
}

// MARK: - Accessibility flags (shared by capture and the rewrite key's field reader)

@Test func accessibilityFlagsPerAppKind() {
    #expect(AppAccessibility.flags(bundleID: "com.google.Chrome", isElectron: false)
        == ["AXManualAccessibility", "AXEnhancedUserInterface"])
    #expect(AppAccessibility.flags(bundleID: "com.tinyspeck.slackmacgap", isElectron: true) == ["AXManualAccessibility"])
    #expect(AppAccessibility.flags(bundleID: "com.apple.mail", isElectron: false).isEmpty)
    // Password managers are never walked: their flags are left alone.
    #expect(AppAccessibility.flags(bundleID: "com.1password.1password", isElectron: true).isEmpty)
}

@Test func accessibilityFlagsAreSetOncePerLaunchAndRetriedWhenBusy() {
    let launches = AppAccessibility.Launches()
    var set: [String] = []
    AppAccessibility.enable(key: "1-0", launches: launches, flags: { ["A"] }, set: { set.append($0) }, unresponsive: { false })
    AppAccessibility.enable(key: "1-0", launches: launches, flags: { ["A"] }, set: { set.append($0) }, unresponsive: { false })
    #expect(set == ["A"])
    // Too busy to take them: a later read tries again.
    AppAccessibility.enable(key: "2-0", launches: launches, flags: { ["B"] }, set: { set.append($0) }, unresponsive: { true })
    AppAccessibility.enable(key: "2-0", launches: launches, flags: { ["B"] }, set: { set.append($0) }, unresponsive: { false })
    AppAccessibility.enable(key: "2-0", launches: launches, flags: { ["B"] }, set: { set.append($0) }, unresponsive: { false })
    #expect(set == ["A", "B", "B"])
}
