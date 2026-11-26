import Capture
import Testing
@testable import MeetingImport

@Test func stoppedCallRemainsSuppressedAcrossUnknownObservations() {
    var policy = MeetingStartPolicy()
    policy.suppress("first")
    #expect(!policy.mayStart("first"))
    #expect(policy.mayStart("second"))
    policy.left()
    #expect(policy.mayStart("first"))
}

@Test func interruptedRoomCanRestartAfterBackoffButManualStopStillWins() {
    var policy = MeetingStartPolicy()
    let now = ContinuousClock.now
    policy.retryAfterInterruption("room", now: now)
    #expect(!policy.mayStart("room", now: now + .seconds(1)))
    #expect(policy.mayStart("room", now: now + .seconds(2)))
    policy.retryAfterInterruption("room", now: now + .seconds(2))
    #expect(!policy.mayStart("room", now: now + .seconds(5)))
    #expect(policy.mayStart("room", now: now + .seconds(6)))
    #expect(policy.mayStart("other", now: now))
    policy.suppress("room")
    policy.retryAfterInterruption("room", now: now)
    #expect(policy.retryingID == nil)
    #expect(!policy.mayStart("room", now: now + .seconds(120)))
}

@Test func losingSightOfAnAutomaticRecordingLeavesTheRoomEligibleForAFreshStart() {
    var policy = MeetingStartPolicy()
    let room = VerifiedMeeting(id: "room", client: .googleMeet, pid: 42, bundleID: "com.google.Chrome",
                               context: WindowContext(app: "Chrome"), micAllowed: false, captions: []).continuity
    #expect(policy.continuityAfterAbsence(room, departureConfirmed: false) == nil)
    #expect(policy.mayStart(room.id))
    policy.suppress(room.id)
    #expect(policy.continuityAfterAbsence(room, departureConfirmed: false) == room)
    #expect(!policy.mayStart(room.id))
    #expect(policy.mayStart("other"))
    #expect(policy.continuityAfterAbsence(nil, departureConfirmed: true) == nil)
    #expect(!policy.mayStart(room.id))
    #expect(policy.continuityAfterAbsence(room, departureConfirmed: true) == nil)
    #expect(policy.mayStart(room.id))
}

@Test func captionNeedsMatchingWordsTimeAndOneSpeaker() {
    var captions = TimedMeetingCaptions()
    captions.observe(text: "Build the sample tomorrow.", speaker: "Alex", at: 10)
    #expect(captions.speaker(for: "build the sample tomorrow", start: 7, end: 9) == "Alex")
    #expect(captions.speaker(for: "Different words", start: 7, end: 9) == nil)
    #expect(captions.speaker(for: "Build the sample tomorrow", start: 50, end: 51) == nil)
    captions.observe(text: "Build the sample tomorrow", speaker: "Sam", at: 11)
    #expect(captions.speaker(for: "Build the sample tomorrow", start: 7, end: 9) == nil)
}

@Test func transcriptOrdersIndependentStreamsAndLeavesOverlappingRemoteSpeechUnnamed() {
    var transcript = MeetingTranscript()
    transcript.captions.observe(text: "The meeting starts now", speaker: "Alex", at: 2)
    transcript.captions.observe(text: "The meeting is over", speaker: "Alex", at: 12)
    transcript.append(text: "Yes", start: 1, end: 2, microphone: true)
    transcript.append(text: "The meeting starts now", start: 0, end: 3, microphone: false)
    transcript.append(text: "The meeting is over", start: 10, end: 12, microphone: false)
    #expect(transcript.rendered() == """
        [0:00] The meeting starts now
        [0:01] You: Yes
        [0:10] Alex: The meeting is over
        """)
}

@Test func changedMeetingContextInterruptsAndNewExclusionsDiscardTheEntireSession() {
    let original = WindowContext(app: "Zoom", bundleID: "us.zoom.xos", windowTitle: "Planning")
    let updated = WindowContext(app: "Zoom", bundleID: "us.zoom.xos", windowTitle: "Review")
    let allow = CapturePolicy(userRules: [])
    #expect(MeetingSourceCheck.evaluate(original: original, current: original, policy: allow) == .verified)
    #expect(MeetingSourceCheck.evaluate(original: original, current: updated, policy: allow) == .changed)
    for pattern in ["title:Planning", "title:Review"] {
        let denied = CapturePolicy(userRules: [ExclusionRule(pattern: pattern)!])
        #expect(MeetingSourceCheck.evaluate(original: original, current: updated, policy: denied) == .denied)
    }
}

@Test func delayedResultsRespectMuteAndLossOfCallVerification() {
    var timeline = MeetingTranscript()
    timeline.withholdMicrophone(after: 3, until: 5)
    timeline.append(text: "First sentence", start: 0, end: 3, microphone: true)
    timeline.append(text: "Private aside", start: 2, end: 4, microphone: true)
    timeline.append(text: "Remote speech", start: 4, end: 5, microphone: false)
    timeline.append(text: "Later sound", start: 5, end: 7, microphone: false)
    #expect(timeline.rendered(through: 5) == "[0:00] You: First sentence\n[0:04] Remote speech")
}

@Test func loudspeakerEchoIsNotRepeatedAsTheLocalSpeaker() {
    var timeline = MeetingTranscript()
    timeline.append(text: "I'll send the update.", start: 8, end: 12, microphone: false)
    timeline.append(text: "I’ll send the update", start: 8.1, end: 12.2, microphone: true)
    #expect(timeline.rendered() == "[0:08] I'll send the update.")
}
