import Foundation
import Testing
@testable import Capture

struct MeetingDetectorTests {
    private let meetURL = URL(string: "https://meet.google.com/abc-defg-hij")!

    @Test func requiresAnExactMeetOriginAndMeetingCode() {
        #expect(MeetingClient.googleMeet.room(at: meetURL) == "abc-defg-hij")
        for address in ["https://meet.google.com.example.com/abc-defg-hij", "https://meet.google.com/",
                        "http://meet.google.com/abc-defg-hij", "https://meet.google.com:444/abc-defg-hij",
                        "https://meet.google.com/landing"] {
            #expect(MeetingClient.googleMeet.room(at: URL(string: address)!) == nil)
        }
        var credentials = URLComponents(url: meetURL, resolvingAgainstBaseURL: false)
        credentials?.user = "fixture"
        #expect(MeetingClient.googleMeet.room(at: credentials?.url) == nil)
    }

    @Test func chromeNeedsPositiveRegularWindowEvidence() {
        #expect(ChromeMeetingWindow.regular(title: "Meet - Google Chrome", pageTitle: "Meet", avatar: nil))
        #expect(ChromeMeetingWindow.regular(title: "Meet - Google Chrome - Person 1", pageTitle: "Meet", avatar: "Person 1"))
        #expect(!ChromeMeetingWindow.regular(title: "Meet - Google Chrome - Person 1", pageTitle: "Meet", avatar: nil))
        #expect(!ChromeMeetingWindow.regular(title: "Meet", pageTitle: "Meet", avatar: nil))
        #expect(!ChromeMeetingWindow.regular(title: "Meet - Google Chrome (Guest)", pageTitle: "Meet", avatar: nil))
        #expect(!ChromeMeetingWindow.regular(title: "Meet - Google Chrome (Navigation privée)", pageTitle: "Meet", avatar: nil))
    }

    @Test func requiresAnExitButtonAndSeparateInCallMediaControl() {
        var controls = MeetingControls()
        controls.observe(button: "Leave call", client: .googleMeet)
        #expect(!controls.joined)
        controls.observe(button: "Turn off camera (⌘ + e)", client: .googleMeet)
        #expect(controls.joined)
        #expect(!controls.micAllowed)
        controls.observe(button: "Turn off microphone (⌘ + d)", client: .googleMeet)
        #expect(controls.micAllowed)
        controls.observe(button: "Turn on microphone (⌘ + d)", client: .googleMeet)
        #expect(!controls.micAllowed)
    }

    @Test func desktopControlsAlsoRecognizeFrenchWithoutMatchingParticipantActions() {
        var zoom = MeetingControls()
        zoom.observe(button: "Quitter la réunion", client: .zoom)
        zoom.observe(button: "Couper mon audio", client: .zoom)
        #expect(zoom.joined && zoom.micAllowed)
        var teams = MeetingControls()
        teams.observe(button: "Leave", client: .teams)
        teams.observe(button: "Mute all participants", client: .teams)
        #expect(!teams.joined)
        teams.observe(button: "Unmute (⌘+Shift+M)", client: .teams)
        #expect(teams.joined && !teams.micAllowed)
    }

    @Test func onlyBrowserOwnedRegularAvatarCanVerifyARawPageTitle() {
        #expect(ChromeMeetingWindow.regular(title: "Meet", pageTitle: "Meet", avatar: "Person 1", knownToolbar: true))
        for name in ["Incognito (2)", "Navigation privée", "Invité", "Guest (2)", ""] {
            #expect(!ChromeMeetingWindow.regular(title: "Meet", pageTitle: "Meet", avatar: name, knownToolbar: true))
        }
    }

    @Test func captionsNeedARecognizedRegionAndUserInputIsSkipped() {
        let region = FakeAXNode(role: "AXGroup", title: "Live captions", children: [
            FakeAXNode(role: "AXGroup", children: [
                FakeAXNode(role: "AXStaticText", value: "Test speaker", nodeDescription: "Speaker"),
                FakeAXNode(role: "AXStaticText", value: "Synthetic caption"),
                FakeAXNode(role: "AXTextField", value: "message draft")])])
        let tree = FakeAXNode(role: "AXWindow", children: [
            FakeAXNode(role: "AXStaticText", value: "chat content"), region])
        #expect(MeetingCaptionReader.read(region: region) == [.init(text: "Synthetic caption", speaker: "Test speaker")])
        #expect(MeetingCaptionReader.read(region: tree).isEmpty)
    }

    @Test func disconnectedAudioOverridesAnOtherwiseUnmutedToolbar() {
        var controls = MeetingControls()
        for button in ["Leave meeting", "Mute my audio", "Join audio"] {
            controls.observe(button: button, client: .zoom)
        }
        #expect(controls.joined && !controls.micAllowed)
    }

    @Test func prejoinAndWaitingStatusOverrideInCallLookingControls() {
        for (client, exit, mic, signal) in [
            (MeetingClient.googleMeet, "Leave call", "Turn off microphone", "Ask to join"),
            (.zoom, "Leave meeting", "Mute my audio", "Waiting for the host to start this meeting"),
            (.teams, "Leave", "Mute", "Join now"),
        ] {
            var controls = MeetingControls()
            controls.observe(button: exit, client: client)
            controls.observe(button: mic, client: client)
            #expect(controls.joined)
            controls.observePrejoinLabel(signal)
            #expect(!controls.joined && !controls.micAllowed)
        }
    }

    @Test func explicitRejoinIsDifferentFromMissingControls() {
        var controls = MeetingControls()
        #expect(!controls.left)
        controls.observe(button: "Rejoin", client: .googleMeet)
        #expect(controls.left)
    }

    @Test func returningToTheSameMeetLobbyCanConfirmDeparture() {
        for label in ["Join now", "Ask to join", "Rejoindre maintenant", "Demander à participer"] {
            var controls = MeetingControls()
            controls.observe(button: label, client: .googleMeet)
            #expect(controls.left)
            controls.observe(button: "Leave call", client: .googleMeet)
            #expect(!controls.left)
        }
        var preview = MeetingControls()
        preview.observePrejoinLabel("Ready to join")
        #expect(!preview.left)
    }

    @Test func privacyDenialPrecedesAmbiguityAndOnlyAPositiveDepartureEndsAPriorCall() {
        #expect(MeetingScanVerdict.resolve(denied: true, issue: .chromeProfile, candidates: 1,
                                           previousProcessExists: true, previousLeft: false) == .denied)
        #expect(MeetingScanVerdict.resolve(denied: false, issue: nil, candidates: 2,
                                           previousProcessExists: false, previousLeft: false) == .unverifiable(.multipleCalls))
        #expect(MeetingScanVerdict.resolve(denied: false, issue: .chromeProfile, candidates: 1,
                                           previousProcessExists: true, previousLeft: true) == .unverifiable(.chromeProfile))
        #expect(MeetingScanVerdict.resolve(denied: false, issue: nil, candidates: 0,
                                           previousProcessExists: true, previousLeft: false) == .noVisibleCall)
        #expect(MeetingScanVerdict.resolve(denied: false, issue: nil, candidates: 0,
                                           previousProcessExists: true, previousLeft: true) == .left)
        #expect(MeetingScanVerdict.resolve(denied: false, issue: nil, candidates: 0,
                                           previousProcessExists: false, previousLeft: false) == .left)
    }

    @Test func excludingAKnownSiblingPageDoesNotDiscardTheRecordingInAnotherChromeWindow() {
        let call = VerifiedMeeting(id: "room", client: .googleMeet, pid: 42, bundleID: "com.google.Chrome",
                                   context: WindowContext(app: "Chrome"), micAllowed: false, captions: [],
                                   windowToken: "call-window").continuity
        let excluded = URL(string: "https://example.com")
        func blocks(_ token: String, _ url: URL?, regular: Bool = true) -> Bool {
            ChromeMeetingWindow.blocksExcludedWindow(token: token, pid: 42, url: url, previous: call, regularSinglePage: regular)
        }
        #expect(!blocks("other-window", excluded))
        #expect(blocks("call-window", excluded))
        #expect(blocks("other-window", meetURL))
        #expect(blocks("other-window", nil))
        #expect(blocks("other-window", excluded, regular: false))
    }

    @Test func denyAllNeverTouchesTheSystemReader() async {
        #expect(await MeetingDetector().detect(policy: .denyAll) == .denied)
        let context = WindowContext(app: "Google Chrome", bundleID: "com.google.Chrome", url: meetURL)
        let previous = VerifiedMeeting(id: "test", client: .googleMeet, pid: -1, bundleID: "com.google.Chrome",
                                       context: context, micAllowed: false, captions: [])
        #expect(previous.continuity == MeetingContinuity(id: "test", client: .googleMeet, pid: -1, bundleID: "com.google.Chrome", windowToken: nil))
        #expect(await MeetingDetector().detect(policy: .denyAll, previous: previous.continuity) == .denied)
    }

}
