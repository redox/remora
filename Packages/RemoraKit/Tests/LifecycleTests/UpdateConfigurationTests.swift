import Foundation
import Testing
@testable import Lifecycle

private let validFeed = "https://github.com/owner/remora/releases/latest/download/appcast.xml"
private let validKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

@Test func validFeedAndKeyAreReady() {
    #expect(UpdateConfiguration.evaluate(feedURL: validFeed, publicKey: validKey, isDebugBuild: false, isInstalled: true)
            == .ready(feed: URL(string: validFeed)!))
}

@Test func debugBuildsNeverUpdate() {
    #expect(UpdateConfiguration.evaluate(feedURL: validFeed, publicKey: validKey, isDebugBuild: true, isInstalled: true)
            == .disabled(.debugBuild))
}

@Test func missingFeedDisablesUpdates() {
    #expect(UpdateConfiguration.evaluate(feedURL: nil, publicKey: validKey, isDebugBuild: false, isInstalled: true) == .disabled(.missingFeed))
    #expect(UpdateConfiguration.evaluate(feedURL: "", publicKey: validKey, isDebugBuild: false, isInstalled: true) == .disabled(.missingFeed))
    #expect(UpdateConfiguration.evaluate(feedURL: "  ", publicKey: validKey, isDebugBuild: false, isInstalled: true) == .disabled(.missingFeed))
}

@Test func emptyRepoMakesFeedInvalid() {
    // What Config/Updates.xcconfig expands to while REMORA_GITHUB_REPO is empty.
    #expect(UpdateConfiguration.evaluate(feedURL: "https://github.com//releases/latest/download/appcast.xml",
                                         publicKey: validKey, isDebugBuild: false, isInstalled: true) == .disabled(.invalidFeed))
}

@Test func unexpandedBuildSettingMakesFeedInvalid() {
    #expect(UpdateConfiguration.evaluate(feedURL: "$(REMORA_FEED_URL)", publicKey: validKey, isDebugBuild: false, isInstalled: true)
            == .disabled(.invalidFeed))
    #expect(UpdateConfiguration.evaluate(feedURL: "https://github.com/$(REMORA_GITHUB_REPO)/releases/latest/download/appcast.xml",
                                         publicKey: validKey, isDebugBuild: false, isInstalled: true) == .disabled(.invalidFeed))
}

@Test func httpFeedIsRejected() {
    #expect(UpdateConfiguration.evaluate(feedURL: "http://example.com/appcast.xml", publicKey: validKey, isDebugBuild: false, isInstalled: true)
            == .disabled(.invalidFeed))
}

@Test func feedWithoutHostOrPathIsRejected() {
    for feed in ["https:///appcast.xml", "https://example.com", "https://example.com/", "not a url", "appcast.xml"] {
        #expect(UpdateConfiguration.evaluate(feedURL: feed, publicKey: validKey, isDebugBuild: false, isInstalled: true) == .disabled(.invalidFeed),
                "\(feed)")
    }
}

@Test func publicKeyMustDecodeTo32Bytes() {
    #expect(UpdateConfiguration.evaluate(feedURL: validFeed, publicKey: nil, isDebugBuild: false, isInstalled: true) == .disabled(.missingKey))
    #expect(UpdateConfiguration.evaluate(feedURL: validFeed, publicKey: "", isDebugBuild: false, isInstalled: true) == .disabled(.missingKey))
    #expect(UpdateConfiguration.evaluate(feedURL: validFeed, publicKey: "abc", isDebugBuild: false, isInstalled: true) == .disabled(.invalidKey))
    #expect(UpdateConfiguration.evaluate(feedURL: validFeed, publicKey: "$(REMORA_SPARKLE_PUBLIC_KEY)", isDebugBuild: false, isInstalled: true)
            == .disabled(.invalidKey))
    let short = Data(repeating: 1, count: 31).base64EncodedString()
    #expect(UpdateConfiguration.evaluate(feedURL: validFeed, publicKey: short, isDebugBuild: false, isInstalled: true) == .disabled(.invalidKey))
    let long = Data(repeating: 1, count: 33).base64EncodedString()
    #expect(UpdateConfiguration.evaluate(feedURL: validFeed, publicKey: long, isDebugBuild: false, isInstalled: true) == .disabled(.invalidKey))
    #expect(UpdateConfiguration.evaluate(feedURL: validFeed, publicKey: validKey, isDebugBuild: false, isInstalled: true)
            == .ready(feed: URL(string: validFeed)!))
}

@Test func feedIsCheckedBeforeKey() {
    #expect(UpdateConfiguration.evaluate(feedURL: nil, publicKey: nil, isDebugBuild: false, isInstalled: true) == .disabled(.missingFeed))
    #expect(UpdateConfiguration.evaluate(feedURL: "http://x.com/a", publicKey: nil, isDebugBuild: false, isInstalled: true) == .disabled(.invalidFeed))
}

@Test func repositoryURLRequiresOwnerAndName() {
    #expect(UpdateConfiguration.repositoryURL("https://github.com/owner/remora") == URL(string: "https://github.com/owner/remora"))
    #expect(UpdateConfiguration.repositoryURL("https://github.com/") == nil)   // empty REMORA_GITHUB_REPO
    #expect(UpdateConfiguration.repositoryURL("https://github.com") == nil)
    #expect(UpdateConfiguration.repositoryURL("https://github.com/owner") == nil)
    #expect(UpdateConfiguration.repositoryURL("https://github.com//remora") == nil)
    #expect(UpdateConfiguration.repositoryURL("https://github.com/$(REMORA_GITHUB_REPO)") == nil)
    #expect(UpdateConfiguration.repositoryURL("$(REMORA_REPOSITORY_URL)") == nil)
    #expect(UpdateConfiguration.repositoryURL("http://github.com/owner/remora") == nil)
    #expect(UpdateConfiguration.repositoryURL(nil) == nil)
    #expect(UpdateConfiguration.repositoryURL("") == nil)
}

/// The values Info.plist expands to before the release settings are filled in (Config/Updates.xcconfig).
@Test func shippedPlaceholderConfigurationIsNotReady() {
    let placeholderFeed = "https://github.com//releases/latest/download/appcast.xml"
    #expect(UpdateConfiguration.evaluate(feedURL: placeholderFeed, publicKey: "", isDebugBuild: false, isInstalled: true) == .disabled(.invalidFeed))
    #expect(UpdateConfiguration.evaluate(feedURL: validFeed, publicKey: "", isDebugBuild: false, isInstalled: true) == .disabled(.missingKey))
    #expect(UpdateConfiguration.evaluate(feedURL: placeholderFeed, publicKey: "", isDebugBuild: true, isInstalled: true) == .disabled(.debugBuild))
    #expect(UpdateConfiguration.repositoryURL("https://github.com/") == nil)
}

/// Goldfish only updates an installed copy: a copy outside Applications (or translocated) gets no updater.
@Test func aCopyOutsideApplicationsGetsNoUpdater() {
    #expect(UpdateConfiguration.evaluate(feedURL: validFeed, publicKey: validKey, isDebugBuild: false, isInstalled: false)
        == .disabled(.notInstalled))
    // A debug build or an unconfigured build says so first.
    #expect(UpdateConfiguration.evaluate(feedURL: validFeed, publicKey: validKey, isDebugBuild: true, isInstalled: false)
        == .disabled(.debugBuild))
    #expect(UpdateConfiguration.evaluate(feedURL: nil, publicKey: validKey, isDebugBuild: false, isInstalled: false)
        == .disabled(.missingFeed))
}
