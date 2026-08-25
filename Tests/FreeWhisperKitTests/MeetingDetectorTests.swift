import Foundation
import Testing

@testable import FreeWhisperKit

@Suite("Meeting detection")
struct MeetingDetectorTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(
        _ bundleID: String?,
        name: String = "App",
        pid: pid_t = 100,
        mic: Bool,
        output: Bool = true
    ) -> AudioProcessSnapshot {
        AudioProcessSnapshot(
            pid: pid,
            bundleID: bundleID,
            name: name,
            isRunningInput: mic,
            isRunningOutput: output
        )
    }

    private var slack: [AudioProcessSnapshot] {
        [snapshot("com.tinyspeck.slackmacgap", name: "Slack", mic: true)]
    }

    // MARK: Starting

    @Test("a Slack huddle is detected once the mic has been held long enough")
    func detectsSlackHuddle() {
        var detector = MeetingDetector()

        #expect(detector.process(slack, now: start) == nil)
        #expect(detector.process(slack, now: start.addingTimeInterval(3)) == nil)

        let event = detector.process(slack, now: start.addingTimeInterval(6))
        guard case .meetingStarted(let meeting) = event else {
            Issue.record("expected a meeting to start, got \(String(describing: event))")
            return
        }
        #expect(meeting.app.kind == .slackHuddle)
        #expect(meeting.displayName == "Slack huddle")
    }

    /// The whole reason detection keys off the microphone rather than output:
    /// Slack plays notification sounds constantly, and none of them are a call.
    @Test("audio output alone never starts a meeting")
    func outputAloneIsNotAMeeting() {
        var detector = MeetingDetector()
        let chiming = [snapshot("com.tinyspeck.slackmacgap", name: "Slack", mic: false, output: true)]

        for offset in stride(from: 0.0, through: 60.0, by: 2.0) {
            #expect(detector.process(chiming, now: start.addingTimeInterval(offset)) == nil)
        }
        #expect(detector.activeMeeting == nil)
    }

    @Test("a brief microphone blip is ignored")
    func briefMicUseIsIgnored() {
        var detector = MeetingDetector()

        #expect(detector.process(slack, now: start) == nil)
        #expect(detector.process(slack, now: start.addingTimeInterval(2)) == nil)
        // Released well before the start delay.
        #expect(detector.process([], now: start.addingTimeInterval(3)) == nil)
        #expect(detector.process([], now: start.addingTimeInterval(30)) == nil)
        #expect(detector.activeMeeting == nil)
    }

    @Test("an unknown app holding the mic is ignored")
    func unknownAppIgnored() {
        var detector = MeetingDetector()
        let voiceMemos = [snapshot("com.apple.VoiceMemos", name: "Voice Memos", mic: true)]

        for offset in stride(from: 0.0, through: 30.0, by: 2.0) {
            #expect(detector.process(voiceMemos, now: start.addingTimeInterval(offset)) == nil)
        }
    }

    @Test("a disabled app is ignored")
    func disabledAppIgnored() {
        let apps = KnownApps.defaults.map { app in
            var copy = app
            if copy.kind == .slackHuddle { copy.isEnabled = false }
            return copy
        }
        var detector = MeetingDetector(apps: apps)

        for offset in stride(from: 0.0, through: 30.0, by: 2.0) {
            #expect(detector.process(slack, now: start.addingTimeInterval(offset)) == nil)
        }
    }

    @Test("switching apps before the delay restarts the clock")
    func switchingAppsRestartsTheClock() {
        var detector = MeetingDetector()
        let zoom = [snapshot("us.zoom.xos", name: "zoom.us", pid: 200, mic: true)]

        #expect(detector.process(slack, now: start) == nil)
        #expect(detector.process(slack, now: start.addingTimeInterval(4)) == nil)
        // Zoom takes over at t=5; its own six seconds start now.
        #expect(detector.process(zoom, now: start.addingTimeInterval(5)) == nil)
        #expect(detector.process(zoom, now: start.addingTimeInterval(8)) == nil)

        let event = detector.process(zoom, now: start.addingTimeInterval(11))
        guard case .meetingStarted(let meeting) = event else {
            Issue.record("expected Zoom to start the meeting")
            return
        }
        #expect(meeting.app.kind == .zoom)
    }

    // MARK: Ending

    @Test("a meeting ends once the mic stays released")
    func endsAfterStopDelay() {
        var detector = MeetingDetector()
        _ = detector.process(slack, now: start)
        _ = detector.process(slack, now: start.addingTimeInterval(6))
        #expect(detector.activeMeeting != nil)

        #expect(detector.process([], now: start.addingTimeInterval(10)) == nil)
        #expect(detector.process([], now: start.addingTimeInterval(20)) == nil)

        let event = detector.process([], now: start.addingTimeInterval(26))
        guard case .meetingEnded = event else {
            Issue.record("expected the meeting to end, got \(String(describing: event))")
            return
        }
        #expect(detector.activeMeeting == nil)
    }

    /// Muting yourself releases the input device in some apps. Ending the
    /// meeting there would stop recording exactly when someone is listening.
    @Test("muting briefly does not end the meeting")
    func mutingDoesNotEndTheMeeting() {
        var detector = MeetingDetector()
        _ = detector.process(slack, now: start)
        _ = detector.process(slack, now: start.addingTimeInterval(6))

        #expect(detector.process([], now: start.addingTimeInterval(8)) == nil)
        #expect(detector.process([], now: start.addingTimeInterval(14)) == nil)
        // Unmuted again, well inside the 15s stop delay.
        #expect(detector.process(slack, now: start.addingTimeInterval(18)) == nil)
        #expect(detector.activeMeeting != nil)

        // And the stop clock must have reset, not carried over.
        #expect(detector.process([], now: start.addingTimeInterval(25)) == nil)
        #expect(detector.activeMeeting != nil)
    }

    @Test("reset clears state so re-enabling detection doesn't fire on history")
    func resetClearsState() {
        var detector = MeetingDetector()
        _ = detector.process(slack, now: start)
        _ = detector.process(slack, now: start.addingTimeInterval(6))
        #expect(detector.activeMeeting != nil)

        detector.reset()
        #expect(detector.activeMeeting == nil)
        #expect(detector.process(slack, now: start.addingTimeInterval(7)) == nil)
    }

    @Test("detection thresholds are configurable")
    func customThresholds() {
        var detector = MeetingDetector(settings: DetectionSettings(startDelay: 1, stopDelay: 2))
        #expect(detector.process(slack, now: start) == nil)

        guard case .meetingStarted = detector.process(slack, now: start.addingTimeInterval(1)) else {
            Issue.record("expected an immediate start with a 1s delay")
            return
        }
        _ = detector.process([], now: start.addingTimeInterval(2))
        guard case .meetingEnded = detector.process([], now: start.addingTimeInterval(4)) else {
            Issue.record("expected an early end with a 2s delay")
            return
        }
    }
}

@Suite("Known app matching")
struct KnownAppsTests {
    private func snapshot(_ bundleID: String?, name: String = "App") -> AudioProcessSnapshot {
        AudioProcessSnapshot(pid: 1, bundleID: bundleID, name: name, isRunningInput: true, isRunningOutput: true)
    }

    @Test("bundle IDs match by prefix, so helper processes resolve to their app")
    func prefixMatching() {
        let chromeHelper = snapshot("com.google.Chrome.helper", name: "Google Chrome Helper")
        #expect(KnownApps.match(chromeHelper, in: KnownApps.defaults)?.kind == .browser)

        let teams = snapshot("com.microsoft.teams2", name: "Microsoft Teams")
        #expect(KnownApps.match(teams, in: KnownApps.defaults)?.kind == .teams)
    }

    @Test("matching is case insensitive")
    func caseInsensitive() {
        let slack = snapshot("COM.TINYSPECK.SLACKMACGAP", name: "Slack")
        #expect(KnownApps.match(slack, in: KnownApps.defaults)?.kind == .slackHuddle)
    }

    /// Safari routes capture through a launchd-owned XPC service, so the parent
    /// walk cannot reach the browser. The process name is the only link left.
    @Test("shared WebKit media services are matched by process name")
    func webKitServiceMatching() {
        let safariGPU = snapshot("com.apple.WebKit.GPU", name: "Safari Graphics and Media")
        #expect(KnownApps.match(safariGPU, in: KnownApps.defaults)?.displayName == "Safari")
    }

    @Test("an unrelated WebKit service does not match a browser we watch")
    func unrelatedWebKitServiceIgnored() {
        let other = snapshot("com.apple.WebKit.GPU", name: "Notion Graphics and Media")
        #expect(KnownApps.match(other, in: KnownApps.defaults) == nil)
    }

    @Test("a process with no bundle ID never matches")
    func noBundleID() {
        #expect(KnownApps.match(snapshot(nil, name: "coreaudiod"), in: KnownApps.defaults) == nil)
    }

    @Test("Slack is watched by default — the gap this tool exists to fill")
    func slackIsWatchedByDefault() {
        let slack = KnownApps.defaults.first { $0.kind == .slackHuddle }
        #expect(slack != nil)
        #expect(slack?.isEnabled == true)
    }
}
