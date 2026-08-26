import Foundation
import Testing

@testable import FreeWhisperKit

@Suite("Meeting prompt policy")
struct MeetingPromptPolicyTests {
    private func decide(
        key: String = "com.tinyspeck.slackmacgap#100",
        seconds: Int = 5,
        recording: Bool = false,
        declined: String? = nil,
        asking: String? = nil
    ) -> MeetingPromptPolicy.Decision {
        MeetingPromptPolicy.decide(
            meetingKey: key,
            countdownSeconds: seconds,
            isRecordingOrStarting: recording,
            declinedKey: declined,
            askingAboutKey: asking
        )
    }

    // MARK: Asking

    @Test("a fresh call is asked about for the configured number of seconds")
    func asksForConfiguredSeconds() {
        #expect(decide(seconds: 5) == .ask(seconds: 5))
        #expect(decide(seconds: 30) == .ask(seconds: 30))
    }

    @Test("zero seconds means the prompt waits for an answer")
    func zeroWaits() {
        #expect(decide(seconds: 0) == .askUntilAnswered)
    }

    /// A value no picker can produce, but an old build or a hand-edited plist
    /// can. Without the guard it would deduct a deadline already in the past and
    /// take the panel away before it had drawn.
    @Test("a negative setting waits rather than expiring instantly")
    func negativeWaits() {
        #expect(decide(seconds: -5) == .askUntilAnswered)
    }

    @Test("the same call re-announced is asked about again, refreshing its deadline")
    func sameCallReAsks() {
        let key = "com.tinyspeck.slackmacgap#100"
        #expect(decide(key: key, asking: key) == .ask(seconds: 5))
    }

    // MARK: Not asking

    @Test("a call is not asked about while one is already being recorded")
    func ignoresWhileRecording() {
        #expect(decide(recording: true) == .ignore(.alreadyRecording))
    }

    @Test("a call the user turned down is not asked about again")
    func ignoresDeclined() {
        let key = "us.zoom.xos#42"
        #expect(decide(key: key, declined: key) == .ignore(.declined))
    }

    /// Declining Zoom must not silence a Slack huddle that starts afterwards.
    @Test("declining one call does not silence a different one")
    func declineIsPerCall() {
        #expect(decide(key: "us.zoom.xos#42", declined: "com.tinyspeck.slackmacgap#100")
            == .ask(seconds: 5))
    }

    @Test("a second call arriving mid-question is dropped, not swapped in")
    func ignoresSecondCall() {
        #expect(decide(key: "us.zoom.xos#42", asking: "com.tinyspeck.slackmacgap#100")
            == .ignore(.alreadyAsking))
    }

    @Test("recording beats declined, and declined beats already-asking")
    func precedence() {
        let key = "us.zoom.xos#42"
        #expect(decide(key: key, recording: true, declined: key, asking: "other#1")
            == .ignore(.alreadyRecording))
        #expect(decide(key: key, declined: key, asking: "other#1") == .ignore(.declined))
    }

    // MARK: Remaining time

    @Test("remaining seconds round up, so the label never reads zero while visible")
    func roundsUp() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(MeetingPromptPolicy.remainingSeconds(until: now.addingTimeInterval(4.2), now: now) == 5)
        #expect(MeetingPromptPolicy.remainingSeconds(until: now.addingTimeInterval(5), now: now) == 5)
        #expect(MeetingPromptPolicy.remainingSeconds(until: now.addingTimeInterval(0.1), now: now) == 1)
    }

    /// The case a lid closed mid-prompt produces: the timer does not fire while
    /// asleep, so the first tick after waking sees a deadline long past.
    @Test("a deadline in the past clamps to zero rather than going negative")
    func clampsExpired() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(MeetingPromptPolicy.remainingSeconds(until: now.addingTimeInterval(-600), now: now) == 0)
        #expect(MeetingPromptPolicy.remainingSeconds(until: now, now: now) == 0)
    }
}

@Suite("Detected meeting identity")
struct DetectedMeetingKeyTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func meeting(_ bundleIDPrefix: String, pid: pid_t) -> DetectedMeeting {
        DetectedMeeting(
            app: KnownApp(bundleIDPrefix: bundleIDPrefix, kind: .other, displayName: "App"),
            pid: pid,
            startedAt: start
        )
    }

    @Test("the same app and pid always produce the same key")
    func stable() {
        #expect(meeting("us.zoom.xos", pid: 42).promptKey == meeting("us.zoom.xos", pid: 42).promptKey)
    }

    @Test("relaunching the app produces a different key, so it is asked about again")
    func differsByPID() {
        #expect(meeting("us.zoom.xos", pid: 42).promptKey != meeting("us.zoom.xos", pid: 43).promptKey)
    }

    /// The separator earns its keep here: without it "com.example.app1" + pid 0
    /// and "com.example.app" + pid 10 are the same string.
    @Test("bundle IDs ending in digits do not collide")
    func separatorPreventsCollision() {
        #expect(meeting("com.example.app1", pid: 0).promptKey != meeting("com.example.app", pid: 10).promptKey)
    }
}
