import Accessibility
import Foundation
import Testing
@testable import Capture

struct GoogleMeetWindowTests {
    @Test func aBrowserComposedRegularTitleWorksWithoutAnAvatarButAPageTitleCannotSupplyItsOwnSuffix() {
        #expect(ChromeMeetingWindow.regular(title: "Room - Google Chrome", pageTitle: "Room", avatar: nil))
        #expect(!ChromeMeetingWindow.regular(title: "Room - Google Chrome", pageTitle: "Room - Google Chrome", avatar: nil))
        #expect(!ChromeMeetingWindow.regular(title: "Room - Google Chrome", pageTitle: nil, avatar: nil))
        for suffix in [" (Incognito)", " (Navigation privée)", " (Guest)", " (isolé)"] {
            #expect(!ChromeMeetingWindow.regular(title: "Room - Google Chrome" + suffix, pageTitle: "Room", avatar: nil))
        }
        #expect(!ChromeMeetingWindow.regular(title: "Room - Google Chrome", pageTitle: "Room", avatar: "Incognito"))
    }

    @Test func chromeCanAnnounceDeviceUseBetweenThePageTitleAndItsOwnWindowSuffix() {
        let titles = ["Room - Camera and microphone recording - Google Chrome",
                      "Room - Audio playing - Google Chrome",
                      "Room – Enregistrement de la caméra et du micro - Google Chrome"]
        for title in titles {
            #expect(ChromeMeetingWindow.regular(title: title, pageTitle: "Room", avatar: nil))
            #expect(!ChromeMeetingWindow.regular(title: title, pageTitle: title, avatar: nil))
            #expect(!ChromeMeetingWindow.regular(title: title + " (Incognito)", pageTitle: "Room", avatar: nil))
            #expect(!ChromeMeetingWindow.regular(title: title, pageTitle: "A different tab", avatar: nil))
        }
        #expect(ChromeMeetingWindow.regular(title: "Room – Enregistrement du micro - Google Chrome – Work",
                                            pageTitle: "Room", avatar: "Work"))
        #expect(!ChromeMeetingWindow.regular(title: "Room - unrecognized detail - Google Chrome",
                                             pageTitle: "Room", avatar: nil))
    }

    @Test func nativeAppMenuStatusVariantsCanIdentifyChromeToolbarLanguage() {
        for label in ["Customise and control Google Chrome", "Customize and control Google Chrome. Update is available.",
                      "Personnalisez et contrôlez Google Chrome. Une mise à jour est disponible."] {
            #expect(ChromeMeetingWindow.isAppMenuLabel(label))
        }
        #expect(!ChromeMeetingWindow.isAppMenuLabel("Learn to customize and control Google Chrome"))
    }

    @Test func chrome158ToolbarVerifiesRegularWindowsAndRejectsPrivateModes() {
        // Chrome names the menu "Chrome". Its localized explanation is separate macOS custom content.
        let menu = FakeAXNode(role: "AXPopUpButton", nodeDescription: "Chrome",
                              nativeClasses: ["BrowserAppMenuButton"], customDescriptions: ["Customize and control Google Chrome"])
        let page = FakeAXNode(role: "AXWebArea", title: "Room")
        for name in ["You", "Incognito", "Guest", "Isolated"] {
            let avatar = FakeAXNode(role: "AXButton", nodeDescription: name, nativeClasses: ["AvatarToolbarButton"])
            let window = FakeAXNode(role: "AXWindow", title: "Room", children: [page, avatar, menu])
            let scan = ChromeMeetingScan.inspect(window, deadline: .now + .seconds(2))
            #expect(scan.knownToolbar)
            #expect(scan.hasRegularSiblingProfile(title: window.title) == (name == "You"))
            #expect(ChromeMeetingWindow.regular(title: window.title, pageTitle: page.title,
                                                avatar: scan.avatar, knownToolbar: scan.knownToolbar) == (name == "You"))
        }
        let privateAvatar = FakeAXNode(role: "AXButton", title: "Profile", domIdentifier: "view_1018",
                                       customDescriptions: ["You're Incognito"])
        let privateWindow = FakeAXNode(role: "AXWindow", children: [page, privateAvatar, menu])
        let privateScan = ChromeMeetingScan.inspect(privateWindow, deadline: .now + .seconds(2))
        #expect(ChromeMeetingWindow.privateAvatar(privateScan.avatar))

        let fakeMenu = FakeAXNode(role: "AXWebArea", children: [menu])
        let window = FakeAXNode(role: "AXWindow", children: [fakeMenu])
        #expect(!ChromeMeetingScan.inspect(window, deadline: .now + .seconds(2)).knownToolbar)
    }

    @Test func chromeMenuDescriptionSurvivesTheMacAccessibilityArchive() throws {
        let entries = [AXCustomContent(label: "description", value: "Customize and control Google Chrome"),
                       AXCustomContent(label: "other", value: "unrelated")]
        let data = try NSKeyedArchiver.archivedData(withRootObject: entries, requiringSecureCoding: true)
        #expect(SystemAXNode.customDescriptions(from: data) == [entries[0].value])
        #expect(SystemAXNode.customDescriptions(from: Data()).isEmpty)
        #expect(SystemAXNode.customDescriptions(from: Data(repeating: 0, count: 33_000)).isEmpty)
    }

    @Test func joinedSoloMeetCanExposeAccessibleTogglesWhileTheInvitationDialogIsOpen() {
        let media = FakeAXNode(role: "AXCheckBox", nodeDescription: "Turn off microphone (⌘ + d)")
        let leave = FakeAXNode(role: "AXButton", nodeDescription: "Leave call")
        let invitation = FakeAXNode(role: "AXDialog", title: "Your meeting’s ready", children: [
            FakeAXNode(role: "AXButton", title: "Add others")])
        let controls = FakeAXNode(role: "AXToolbar", children: [media, leave])
        #expect(read([invitation, controls]).joined)
        #expect(read([invitation, controls]).micAllowed)
        #expect(!read([invitation]).joined)
        let prejoin = FakeAXNode(role: "AXDialog", children: [FakeAXNode(role: "AXButton", title: "Join now")])
        #expect(!read([prejoin, controls]).joined)
        let fakeExit = FakeAXNode(role: "AXCheckBox", title: "Leave call")
        #expect(!read([fakeExit, media]).joined)
    }

    @Test(arguments: ["AXTabGroup", "AXGroup"])
    func nativeTabButtonsDoNotHideTheActiveMeetPageWhenChromeHasManyTabs(_ stripRole: String) {
        let page = FakeAXNode(role: "AXWebArea", pageURL: URL(string: "https://meet.google.com/abc-defg-hij"))
        let tabs = Array(repeating: FakeAXNode(role: "AXRadioButton"), count: 120)
        let strip = FakeAXNode(role: stripRole, children: tabs, domIdentifier: "view_21")
        let window = FakeAXNode(role: "AXWindow", children: [strip, page])
        let scan = ChromeMeetingScan.inspect(window, deadline: .now + .seconds(2))
        #expect(scan.complete)
        #expect(scan.pageCount == 1)
        #expect(scan.url == page.pageURL)

        let unrecognized = FakeAXNode(role: "AXTabGroup", children: tabs)
        let other = FakeAXNode(role: "AXWindow", children: [unrecognized, page])
        let wide = ChromeMeetingScan.inspect(other, deadline: .now + .seconds(2))
        #expect(wide.complete && wide.pageCount == 1)
    }

    @Test func oversizedNativeSelectorsLeaveBothDocumentPanesVisibleToVerification() {
        let items = Array(repeating: FakeAXNode(role: "AXButton"), count: 450)
        let bookmarks = FakeAXNode(role: "AXToolbar", children: items, nativeClasses: ["BookmarkBarView"])
        let strip = FakeAXNode(role: "AXUnknown", children: items, nativeClasses: ["TabStrip"])
        let room = FakeAXNode(role: "AXWebArea", pageURL: URL(string: "https://meet.google.com/abc-defg-hij"))
        let other = FakeAXNode(role: "AXWebArea", pageURL: URL(string: "https://example.com"))
        let window = FakeAXNode(role: "AXWindow", children: [bookmarks, strip, room, other])
        let scan = ChromeMeetingScan.inspect(window, deadline: .now + .seconds(2))
        #expect(scan.complete && scan.pageCount == 2)
        let reversed = ChromeMeetingScan.inspect(FakeAXNode(role: "AXWindow", children: [other, room]),
                                                deadline: .now + .seconds(2))
        #expect(reversed.pageCount == 2 && reversed.url == room.pageURL)
    }

    @Test func meetingScanTraversesUnknownContainersUntilTheTotalBudgetIsExhausted() {
        let room = FakeAXNode(role: "AXWebArea", pageURL: URL(string: "https://meet.google.com/abc-defg-hij"))
        var other = FakeAXNode(role: "AXWebArea", pageURL: URL(string: "https://example.com"))
        for _ in 0..<14 { other = FakeAXNode(role: "AXGroup", children: [other]) }
        let deep = ChromeMeetingScan.inspect(FakeAXNode(role: "AXWindow", children: [room, other]),
                                            deadline: .now + .seconds(2))
        #expect(deep.complete && deep.pageCount == 2)
        let large = FakeAXNode(role: "AXGroup", children: Array(repeating: other, count: 450))
        let incomplete = ChromeMeetingScan.inspect(FakeAXNode(role: "AXWindow", children: [room, large]),
                                                  deadline: .now + .seconds(2))
        #expect(incomplete.issue == .chromeWindowSize)
    }

    @Test func aMissingBatchedRoleIsVerifiedWithTheIndividualRoleAttribute() {
        let page = FakeAXNode(role: "AXWebArea", pageURL: URL(string: "https://meet.google.com/abc-defg-hij"),
                              missingBatchedRole: true)
        let window = FakeAXNode(role: "AXWindow", children: [page])
        let scan = ChromeMeetingScan.inspect(window, deadline: .now + .seconds(2))
        #expect(scan.complete && scan.pageCount == 1 && scan.url == page.pageURL)

        let unknown = FakeAXNode(children: [page], missingBatchedRole: true)
        let incomplete = ChromeMeetingScan.inspect(unknown, deadline: .now + .seconds(2))
        #expect(incomplete.issue == .chromeRole)
        let missing = FakeAXNode(role: "AXGroup", unreadableChildren: true)
        #expect(ChromeMeetingScan.inspect(missing, deadline: .now + .seconds(2)).issue == .chromeChildren)
    }

    @Test func anInvalidChildRangeCountsAsEmptyOnlyWhenAXConfirmsZeroChildren() {
        #expect(AXReadSession.confirmedEmptyRange(.illegalArgument, count: { 0 }))
        #expect(!AXReadSession.confirmedEmptyRange(.illegalArgument, count: { nil }))
        #expect(!AXReadSession.confirmedEmptyRange(.illegalArgument, count: { 1 }))
        #expect(!AXReadSession.confirmedEmptyRange(.cannotComplete, count: { Issue.record("Retried a timeout"); return 0 }))
    }

    @Test func anUnreadableCallControlsBranchCannotSilentlyCountAsEmpty() {
        let page = FakeAXNode(role: "AXWebArea", children: [
            FakeAXNode(role: "AXButton", title: "Leave call"),
            FakeAXNode(role: "AXButton", title: "Turn off microphone"),
            FakeAXNode(role: "AXGroup", unreadableChildren: true)])
        var reader = MeetingControlReader<FakeAXNode>(client: .googleMeet, deadline: .now + .seconds(2))
        reader.read(page)
        #expect(!reader.complete)
    }

    @Test func unchangedMeetWindowStillHasTimeForItsFinalCheckAfterSlowDiscovery() {
        let start = ContinuousClock.now
        let deadline = start + .seconds(2)
        let finished = deadline - .milliseconds(20)
        #expect(MeetingDetector.finalDeadline(for: .googleMeet, discoveredAt: finished,
                                              discoveryDeadline: deadline) == finished + .milliseconds(750))
        #expect(MeetingDetector.finalDeadline(for: .googleMeet, discoveredAt: start,
                                              discoveryDeadline: deadline) == deadline)
        #expect(MeetingDetector.finalDeadline(for: .teams, discoveredAt: finished,
                                              discoveryDeadline: deadline) == deadline)
    }

    private func read(_ children: [FakeAXNode]) -> MeetingControls {
        var reader = MeetingControlReader<FakeAXNode>(client: .googleMeet, deadline: .now + .seconds(2))
        reader.read(FakeAXNode(role: "AXWebArea", children: children))
        return reader.controls
    }
}

extension FakeAXNode: WindowAXElement {
    var chromeIdentity: ChromeControlIdentity { .init(role: missingBatchedRole ? nil : role, id: domIdentifier, classes: nativeClasses) }
    var chromeButtonLabels: [String] { [title, nodeDescription].compactMap { $0 } }
    func verificationChildren(upTo limit: Int) -> [Self]? { unreadableChildren ? nil : children(upTo: limit) }
    var controlReadable: Bool { true }
    var controlEnabled: Bool { true }
    func children(upTo limit: Int) -> [Self] { children.prefix(limit).compactMap { $0 as? Self } }
}
