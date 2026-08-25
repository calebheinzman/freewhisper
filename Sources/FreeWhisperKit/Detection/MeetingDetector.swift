import Foundation

public struct DetectedMeeting: Sendable, Equatable {
    public let app: KnownApp
    public let pid: pid_t
    public let startedAt: Date

    public var displayName: String { app.kind.displayName }
}

public struct DetectionSettings: Sendable, Equatable {
    /// How long an app must hold the microphone before we call it a meeting.
    ///
    /// This is the anti-false-positive knob. Notification sounds are output
    /// only and never trip it, but a quick "test your mic" click or Slack
    /// briefly opening the input device would, without a few seconds of
    /// hysteresis.
    public var startDelay: TimeInterval = 6
    /// How long the microphone must stay released before we call it over.
    /// Generous, because muting yourself can release the input device on some
    /// apps and we must not end the meeting when someone mutes.
    public var stopDelay: TimeInterval = 15

    public init(startDelay: TimeInterval = 6, stopDelay: TimeInterval = 15) {
        self.startDelay = startDelay
        self.stopDelay = stopDelay
    }
}

/// Decides when a call has started and ended, from audio-process snapshots.
///
/// Pure state machine with an injected clock: no timers, no CoreAudio, no
/// notifications. Everything about the detection rules is therefore testable
/// without needing an actual meeting.
public struct MeetingDetector: Sendable {
    public enum Event: Sendable, Equatable {
        case meetingStarted(DetectedMeeting)
        case meetingEnded(DetectedMeeting)
    }

    public private(set) var settings: DetectionSettings
    public private(set) var apps: [KnownApp]

    /// Candidate currently holding the mic but not yet past `startDelay`.
    private var candidate: (app: KnownApp, pid: pid_t, since: Date)?
    /// The confirmed meeting, if any.
    private var active: DetectedMeeting?
    /// When the active meeting's app last released the microphone.
    private var releasedAt: Date?

    public init(settings: DetectionSettings = DetectionSettings(), apps: [KnownApp] = KnownApps.defaults) {
        self.settings = settings
        self.apps = apps
    }

    public var activeMeeting: DetectedMeeting? { active }

    public var pendingCandidate: (app: KnownApp, since: Date)? {
        candidate.map { ($0.app, $0.since) }
    }

    public mutating func update(settings: DetectionSettings) {
        self.settings = settings
    }

    public mutating func update(apps: [KnownApp]) {
        self.apps = apps
    }

    /// Feed a snapshot of what the HAL currently reports. Returns any state
    /// transition it caused.
    public mutating func process(
        _ snapshots: [AudioProcessSnapshot],
        now: Date = Date()
    ) -> Event? {
        // A meeting is an enabled known app holding the *microphone*. Output
        // alone is just audio playing — that's what makes this immune to
        // notification chimes and music.
        let candidates = snapshots.filter { snapshot in
            guard snapshot.isRunningInput else { return false }
            guard let app = KnownApps.match(snapshot, in: apps) else { return false }
            return app.isEnabled
        }

        if let active {
            return processWhileActive(active, candidates: candidates, now: now)
        }
        return processWhileIdle(candidates: candidates, now: now)
    }

    private mutating func processWhileIdle(
        candidates: [AudioProcessSnapshot],
        now: Date
    ) -> Event? {
        guard let snapshot = candidates.first,
              let app = KnownApps.match(snapshot, in: apps) else {
            candidate = nil
            return nil
        }

        // Restart the clock if a different app took over the microphone.
        if candidate?.app.bundleIDPrefix != app.bundleIDPrefix {
            candidate = (app, snapshot.pid, now)
            return nil
        }

        guard let candidate, now.timeIntervalSince(candidate.since) >= settings.startDelay else {
            return nil
        }

        let meeting = DetectedMeeting(app: candidate.app, pid: candidate.pid, startedAt: candidate.since)
        active = meeting
        self.candidate = nil
        releasedAt = nil
        Log.detection.notice("meeting detected: \(meeting.displayName, privacy: .public)")
        return .meetingStarted(meeting)
    }

    private mutating func processWhileActive(
        _ meeting: DetectedMeeting,
        candidates: [AudioProcessSnapshot],
        now: Date
    ) -> Event? {
        let stillRunning = candidates.contains { snapshot in
            KnownApps.match(snapshot, in: apps)?.bundleIDPrefix == meeting.app.bundleIDPrefix
        }

        if stillRunning {
            // Reacquired the mic — the user was probably just muted.
            releasedAt = nil
            return nil
        }

        guard let releasedAt else {
            self.releasedAt = now
            return nil
        }

        guard now.timeIntervalSince(releasedAt) >= settings.stopDelay else { return nil }

        active = nil
        self.releasedAt = nil
        Log.detection.notice("meeting ended: \(meeting.displayName, privacy: .public)")
        return .meetingEnded(meeting)
    }

    /// Forget all state — used when the user turns auto-detection off, so
    /// turning it back on doesn't immediately fire on stale history.
    public mutating func reset() {
        candidate = nil
        active = nil
        releasedAt = nil
    }
}
