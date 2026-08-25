import AppKit
import Foundation
import FreeWhisperKit
import Observation

/// What the app is doing right now. The menu bar renders directly off this, so
/// the user can always tell whether we are recording — the single most
/// important trust property in a tool like this.
enum AppPhase: Equatable {
    case idle
    /// A meeting was detected and we're counting down before auto-recording.
    case meetingDetected(app: String, secondsRemaining: Int)
    /// Opening the audio streams. Can sit here a while on first run, waiting on
    /// the system audio permission prompt.
    case starting
    case recording(startedAt: Date)
    case processing(step: String)

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    /// Whether the Start/Stop button should read "Stop".
    var isActive: Bool {
        switch self {
        case .recording, .starting: true
        default: false
        }
    }
}

@Observable
@MainActor
final class AppCoordinator {
    private(set) var phase: AppPhase = .idle
    private(set) var status = RecordingStatus()
    private(set) var lastError: String?
    private(set) var meetings: [MeetingMetadata] = []

    let permissions = PermissionsModel()
    let dictation = DictationController()
    let screenshots = ScreenshotController()
    let models = ModelSetupModel.shared

    @ObservationIgnored private let store = MeetingStore.shared
    @ObservationIgnored private var session: RecordingSession?
    @ObservationIgnored private var statusTimer: Timer?
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private let watcher = MeetingWatcher()
    @ObservationIgnored private var countdownTimer: Timer?
    @ObservationIgnored private var pendingMeeting: DetectedMeeting?
    /// Meetings the user declined, so we don't re-prompt for the same call.
    @ObservationIgnored private var declinedMeetingKey: String?
    /// True when recording was started by detection, so we can stop it when the
    /// call ends. A manually started recording is never stopped automatically.
    @ObservationIgnored private var recordingWasAutoStarted = false

    /// Master switch. Off means we never auto-start, never listen for meetings,
    /// and the menu bar says so plainly.
    var autoDetectEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoDetectEnabled, forKey: Self.autoDetectKey)
            syncWatcher()
        }
    }

    private static let autoDetectKey = SettingsKeys.autoDetect

    /// Which speech model meetings use. Read here rather than passed in so
    /// the setting applies to auto-transcription as well as manual runs.
    var transcriptionModel: ModelCatalog.Model {
        ModelCatalog.transcriber(
            id: UserDefaults.standard.string(forKey: SettingsKeys.transcriptionModel),
            or: ModelCatalog.defaultTranscriber
        )
    }

    var autoTranscribe: Bool {
        UserDefaults.standard.bool(forKey: SettingsKeys.autoTranscribe)
    }

    /// Seconds before auto-recording a detected meeting. 0 means notify only.
    var autoStartCountdown: Int {
        UserDefaults.standard.integer(forKey: SettingsKeys.autoStartCountdown)
    }

    init() {
        SettingsKeys.registerDefaults()
        autoDetectEnabled = UserDefaults.standard.bool(forKey: Self.autoDetectKey)
    }

    func onAppear() async {
        await permissions.refresh()
        reloadMeetings()
        Log.app.info("FreeWhisper ready; auto-detect=\(self.autoDetectEnabled, privacy: .public)")
    }

    @ObservationIgnored private var hasStarted = false

    /// Launch-time setup. Idempotent: the menu bar label's onAppear can fire
    /// more than once over the app's life.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        SettingsKeys.registerDefaults()
        // Before anything can ask whether a model is present: earlier builds put
        // the CoreML weights in ~/Documents, and this moves them without a
        // re-download.
        ModelStorage.migrateFromDocumentsIfNeeded()
        store.repairInterruptedMeetings()
        dictation.start()
        screenshots.start(coordinator: self)
        observeDictationState()
        MeetingNotifier.shared.register()
        MeetingNotifier.shared.onResponse = { [weak self] response in
            switch response {
            case .record: self?.acceptPendingMeeting()
            case .dismiss: self?.declinePendingMeeting()
            }
        }
        syncWatcher()

        // Fetch whatever the shipped configuration needs, then warm the
        // dictation model. Downloading here rather than on first use matters:
        // lazily, the first inference is the moment right after the user's
        // first real meeting, and a 600 MB download that fails offline would
        // lose them the transcript of a call they have already had.
        Task {
            await models.downloadDefaultsIfNeeded()

            // Only after the weights exist, and only for dictation, whose whole
            // value is that text appears the instant you stop talking.
            // A cloud engine has nothing to preload — no weights, no warm-up —
            // and preparing it would only log a config error at every launch.
            guard models.defaultsAreReady else { return }
            let model = self.dictation.model
            guard model.engine?.isOnDevice == true else { return }
            Task.detached(priority: .utility) {
                await EngineRegistry.shared.preload(model)
            }
        }

        // The detection notification is how the user consents to a recording,
        // so it is worth asking for up front rather than discovering at the
        // start of a call that we have no way to ask.
        Task {
            if autoDetectEnabled, await Permissions.notificationState() == .notDetermined {
                _ = await Permissions.requestNotifications()
                await permissions.refresh()
            }
        }

        observeActivation()
    }

    /// Granting a permission happens in System Settings, in another process, and
    /// macOS tells us nothing when it does. Coming back to FreeWhisper is the one
    /// moment we know something might have changed, so re-read everything then.
    ///
    /// This is also the only thing that revives the dictation chord: its event
    /// tap cannot be created without Accessibility, and without a re-arm here it
    /// stays dead until the app is relaunched, with nothing on screen saying why.
    private func observeActivation() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.permissions.refresh()
                self.dictation.rearmChordIfNeeded()
            }
        }
    }

    // MARK: Dictation

    @ObservationIgnored private let hud = DictationHUD()
    @ObservationIgnored private var hudTimer: Timer?

    /// The HUD is driven by polling rather than by observing `state` directly:
    /// the controller is updated from a global hotkey handler, and a 10 Hz poll
    /// is simpler than threading observation through an AppKit panel.
    private func observeDictationState() {
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.dictation.state == .idle {
                    self.hud.hide()
                } else {
                    self.hud.show(controller: self.dictation)
                }
            }
        }
        hudTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: Detection

    /// Apps to watch: the built-in list plus anything the user added via the
    /// `watchedApps` default (an array of bundle ID prefixes).
    private var watchedApps: [KnownApp] {
        let extra = (UserDefaults.standard.array(forKey: SettingsKeys.watchedApps) as? [String]) ?? []
        return KnownApps.defaults + extra.compactMap { bundleID in
            guard !KnownApps.defaults.contains(where: { bundleID.hasPrefix($0.bundleIDPrefix) }) else {
                return nil
            }
            return KnownApp(bundleIDPrefix: bundleID, kind: .other, displayName: bundleID)
        }
    }

    private func syncWatcher() {
        guard autoDetectEnabled else {
            watcher.stop()
            cancelCountdown()
            return
        }
        watcher.update(apps: watchedApps)
        watcher.start { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: MeetingDetector.Event) {
        switch event {
        case .meetingStarted(let meeting):
            beginCountdown(for: meeting)
        case .meetingEnded(let meeting):
            MeetingNotifier.shared.clear()
            cancelCountdown()
            declinedMeetingKey = nil
            // Only stop what detection started. If the user hit Start
            // themselves, it is not ours to end.
            if phase.isRecording, recordingWasAutoStarted {
                Log.detection.notice("\(meeting.displayName, privacy: .public) ended; stopping recording")
                stopRecording()
            }
        }
    }

    private func beginCountdown(for meeting: DetectedMeeting) {
        guard !phase.isActive else { return }

        let key = meeting.app.bundleIDPrefix + String(meeting.pid)
        guard declinedMeetingKey != key else { return }

        pendingMeeting = meeting
        let seconds = autoStartCountdown
        MeetingNotifier.shared.notifyMeetingDetected(meeting, autoStartIn: seconds)

        guard seconds > 0 else {
            // Notify-only mode: show it in the menu bar but never auto-start.
            phase = .meetingDetected(app: meeting.displayName, secondsRemaining: 0)
            return
        }

        // Show the detected state right away; whether it counts down is decided
        // below.
        phase = .meetingDetected(app: meeting.displayName, secondsRemaining: seconds)

        // The countdown notification *is* the consent step — it is what carries
        // the "Not now" button. If it cannot be delivered, because notifications
        // are denied or a Focus mode is swallowing them, auto-starting would
        // begin recording a conversation that other people are in while giving
        // the user no visible chance to stop it. So fall back to notify-only and
        // let them start it from the menu bar instead.
        Task { @MainActor in
            guard await Permissions.notificationState() == .authorized else {
                Log.detection.notice("notifications not authorized; not auto-starting")
                self.phase = .meetingDetected(app: meeting.displayName, secondsRemaining: 0)
                return
            }
            self.startCountdownTimer(for: meeting, seconds: seconds)
        }
    }

    private func startCountdownTimer(for meeting: DetectedMeeting, seconds: Int) {
        // The permission check above is async, so the user may have dismissed the
        // meeting in the meantime.
        guard case .meetingDetected = phase, pendingMeeting?.pid == meeting.pid else { return }

        var remaining = seconds

        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, case .meetingDetected = self.phase else { return }
                remaining -= 1
                if remaining <= 0 {
                    self.acceptPendingMeeting()
                } else {
                    self.phase = .meetingDetected(app: meeting.displayName, secondsRemaining: remaining)
                }
            }
        }
        countdownTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func acceptPendingMeeting() {
        guard let meeting = pendingMeeting else { return }
        cancelCountdown()
        MeetingNotifier.shared.clear()
        recordingWasAutoStarted = true
        startRecording(detectedApp: meeting.app.displayName, meetingKind: meeting.app.kind.rawValue)
    }

    func declinePendingMeeting() {
        if let meeting = pendingMeeting {
            declinedMeetingKey = meeting.app.bundleIDPrefix + String(meeting.pid)
            Log.detection.notice("declined \(meeting.displayName, privacy: .public)")
        }
        cancelCountdown()
        MeetingNotifier.shared.clear()
        phase = .idle
    }

    private func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        pendingMeeting = nil
        if case .meetingDetected = phase { phase = .idle }
    }

    /// The meeting a screenshot should attach to.
    ///
    /// Non-nil only while genuinely recording — not while starting, not while
    /// a call has merely been detected — so a stray hotkey press can say so
    /// rather than writing a PNG into a meeting nobody will look at.
    var recordingMeeting: MeetingMetadata? {
        guard phase.isRecording else { return nil }
        return session?.metadata
    }

    func refreshPermissions() async {
        await permissions.refresh()
    }

    func reloadMeetings() {
        meetings = store.list()
    }

    // MARK: Recording

    func toggleRecording() {
        if phase.isActive {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording(detectedApp: String? = nil, meetingKind: String? = nil) {
        guard session == nil, !isStarting else { return }
        if detectedApp == nil { recordingWasAutoStarted = false }
        lastError = nil
        isStarting = true
        phase = .starting

        // Starting must not run on the main actor. Creating the process tap
        // blocks until the user answers the audio-capture permission prompt, and
        // doing that inline freezes the whole menu bar panel behind the dialog.
        Task {
            do {
                let session = try await Task.detached(priority: .userInitiated) {
                    let session = try RecordingSession(
                        detectedApp: detectedApp,
                        meetingKind: meetingKind
                    )
                    try session.start()
                    return session
                }.value

                self.session = session
                self.isStarting = false
                self.phase = .recording(startedAt: session.metadata.startedAt)
                self.startStatusPolling()
            } catch {
                self.isStarting = false
                self.phase = .idle
                self.lastError = error.localizedDescription
                Log.app.error("could not start recording: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func stopRecording() {
        guard let session else { return }
        stopStatusPolling()

        let metadata = session.stop()
        self.session = nil
        recordingWasAutoStarted = false
        status = RecordingStatus()
        phase = .idle
        reloadMeetings()

        Log.app.info("recording finished: \(metadata.id, privacy: .public)")

        if autoTranscribe {
            transcribeInBackground(meetingID: metadata.id)
        }
    }

    /// Transcribe after the call ends rather than during it. Whisper on a
    /// 600 MB model is not free, and running it live would compete with the
    /// meeting itself for CPU.
    private func transcribeInBackground(meetingID: String) {
        let model = self.transcriptionModel
        phase = .processing(step: "Transcribing…")

        Task {
            let pipeline = TranscriptionPipeline(store: store)
            do {
                _ = try await pipeline.run(meetingID: meetingID, model: model) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard case .processing = self?.phase else { return }
                        self?.phase = .processing(step: Self.describe(progress))
                    }
                }

                if LLMSettings.summarizationEnabled {
                    // A summarization failure must not lose the transcript,
                    // which is the part that took a meeting to produce.
                    do {
                        _ = try await pipeline.summarize(meetingID: meetingID) { [weak self] step in
                            Task { @MainActor [weak self] in
                                guard case .processing = self?.phase else { return }
                                self?.phase = .processing(step: step)
                            }
                        }
                    } catch {
                        self.lastError = "Transcript saved, but summarizing failed: \(error.localizedDescription)"
                        Log.llm.error("summarization failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            } catch {
                self.lastError = error.localizedDescription
                Log.transcription.error("auto-transcription failed: \(error.localizedDescription, privacy: .public)")
            }
            // Only clear the phase if nothing else has taken over — a new
            // recording may well have started while this was running.
            if case .processing = self.phase { self.phase = .idle }
            self.reloadMeetings()
        }
    }

    private static func describe(_ progress: EngineProgress) -> String {
        switch progress {
        case .downloadingModel(let name, _): "Preparing \(name)…"
        case .loadingModel: "Loading model…"
        case .transcribing: "Transcribing…"
        case .diarizing: "Identifying speakers…"
        }
    }

    /// Polls rather than pushing: the capture callbacks run on real-time audio
    /// threads and must not be hopping to the main actor 20 times a second.
    private func startStatusPolling() {
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let session = self.session else { return }
                self.status = session.status()
            }
        }
        statusTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopStatusPolling() {
        statusTimer?.invalidate()
        statusTimer = nil
    }
}
