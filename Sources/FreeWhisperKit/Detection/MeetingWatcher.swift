import Foundation

/// Runs the detector against live CoreAudio state.
///
/// Thin on purpose: all the actual rules live in `MeetingDetector`, which is a
/// pure state machine and therefore testable without a real meeting.
public final class MeetingWatcher: @unchecked Sendable {
    public typealias EventHandler = @Sendable (MeetingDetector.Event) -> Void

    private let monitor: AudioProcessMonitor
    private let lock = NSLock()
    private var detector: MeetingDetector
    private var handler: EventHandler?
    private var isRunning = false

    public init(
        settings: DetectionSettings = DetectionSettings(),
        apps: [KnownApp] = KnownApps.defaults,
        pollInterval: TimeInterval = 2
    ) {
        self.detector = MeetingDetector(settings: settings, apps: apps)
        self.monitor = AudioProcessMonitor(interval: pollInterval)
    }

    deinit { stop() }

    public var activeMeeting: DetectedMeeting? {
        lock.lock(); defer { lock.unlock() }
        return detector.activeMeeting
    }

    public func start(handler: @escaping EventHandler) {
        lock.lock()
        guard !isRunning else { lock.unlock(); return }
        isRunning = true
        self.handler = handler
        lock.unlock()

        Log.detection.info("watching for meetings")

        // AudioProcessMonitor only reports changes, but the detector's rules are
        // time-based: it needs a tick even when nothing changed, or a call that
        // starts and then stays steady would never cross the start delay.
        monitor.start { [weak self] snapshots in
            self?.feed(snapshots)
        }
        startTicking()
    }

    public func stop() {
        lock.lock()
        guard isRunning else { lock.unlock(); return }
        isRunning = false
        handler = nil
        detector.reset()
        lock.unlock()

        monitor.stop()
        ticker?.cancel()
        ticker = nil
        Log.detection.info("stopped watching")
    }

    public func update(apps: [KnownApp]) {
        lock.lock(); defer { lock.unlock() }
        detector.update(apps: apps)
    }

    public func update(settings: DetectionSettings) {
        lock.lock(); defer { lock.unlock() }
        detector.update(settings: settings)
    }

    /// What the user sees counting down in the menu bar: seconds a candidate has
    /// been holding the mic, or nil when there's nothing pending.
    public func pendingCandidate() -> (app: KnownApp, elapsed: TimeInterval)? {
        lock.lock(); defer { lock.unlock() }
        guard let pending = detector.pendingCandidate else { return nil }
        return (pending.app, Date().timeIntervalSince(pending.since))
    }

    // MARK: Internals

    private var ticker: DispatchSourceTimer?
    private var lastSnapshots: [AudioProcessSnapshot] = []

    private func startTicking() {
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "dev.freewhisper.detector-tick")
        )
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let snapshots = self.lastSnapshots
            self.lock.unlock()
            self.feed(snapshots, refreshCache: false)
        }
        ticker = timer
        timer.resume()
    }

    private func feed(_ snapshots: [AudioProcessSnapshot], refreshCache: Bool = true) {
        lock.lock()
        guard isRunning else { lock.unlock(); return }
        if refreshCache { lastSnapshots = snapshots }
        let event = detector.process(snapshots)
        let handler = self.handler
        lock.unlock()

        guard let event else { return }
        handler?(event)
    }
}
