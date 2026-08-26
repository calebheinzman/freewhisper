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
    @ObservationIgnored private let prompt = MeetingPrompt()
    @ObservationIgnored private var countdownTimer: Timer?
    /// When the on-screen prompt gives up, or nil if it waits for an answer.
    @ObservationIgnored private var promptDeadline: Date?
    @ObservationIgnored private var pendingMeeting: DetectedMeeting?
    /// Meetings the user declined, so we don't re-prompt for the same call.
    @ObservationIgnored private var declinedMeetingKey: String?
    /// True when this recording is bound to a detected call — the user answered
    /// the prompt about *that* call, so that call ending is where the recording
    /// belongs. A manually started recording is never stopped automatically.
    @ObservationIgnored private var recordingFollowsDetectedCall = false

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

    /// How long the "record this call?" panel stays up before giving up. 0 means
    /// it waits until answered. Nothing here ever starts a recording on its own.
    var promptTimeout: Int {
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
            guard models.defaultsAreReady else { return }
            self.warmDictationModel()
        }

        observeActivation()
    }

    func warmDictationModel() {
        DictationWarmup.warm(dictation.model)
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
            dismissPrompt()
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
            askAbout(meeting)
        case .meetingEnded(let meeting):
            dismissPrompt()
            // `declinedMeetingKey` is deliberately not cleared here. An app that
            // releases the mic for longer than `stopDelay` and then reacquires it
            // — which muting does on some clients — produces exactly this event
            // pair, and clearing here meant "won't be asked about again" was
            // never true in the one case it exists for. `present` clears it
            // instead, when a genuinely different call turns up.
            //
            // Only stop what the prompt started. If the user hit Start
            // themselves, it is not ours to end.
            if phase.isRecording, recordingFollowsDetectedCall {
                Log.detection.notice("\(meeting.displayName, privacy: .public) ended; stopping recording")
                stopRecording()
            }
        }
    }

    private func askAbout(_ meeting: DetectedMeeting) {
        switch MeetingPromptPolicy.decide(
            meetingKey: meeting.promptKey,
            countdownSeconds: promptTimeout,
            isRecordingOrStarting: phase.isActive,
            declinedKey: declinedMeetingKey,
            askingAboutKey: pendingMeeting?.promptKey
        ) {
        case .ignore(let reason):
            Log.detection.info("""
                not asking about \(meeting.displayName, privacy: .public): \
                \(reason.rawValue, privacy: .public)
                """)
        case .askUntilAnswered:
            present(meeting, deadline: nil)
        case .ask(let seconds):
            present(meeting, deadline: Date().addingTimeInterval(TimeInterval(seconds)))
        }
    }

    private func present(_ meeting: DetectedMeeting, deadline: Date?) {
        pendingMeeting = meeting
        promptDeadline = deadline
        // A different call than the one that was turned down: that "no" is spent.
        if declinedMeetingKey != meeting.promptKey { declinedMeetingKey = nil }

        let seconds = deadline.map { MeetingPromptPolicy.remainingSeconds(until: $0) } ?? 0
        phase = .meetingDetected(app: meeting.displayName, secondsRemaining: seconds)

        prompt.show(
            app: meeting.displayName,
            deadline: deadline,
            onRecord: { [weak self] in self?.acceptPendingMeeting() },
            onDismiss: { [weak self] in self?.declinePendingMeeting() }
        )

        guard deadline != nil else { return }
        startPromptTimer()
    }

    /// Ticks the label and enforces the deadline.
    ///
    /// The remaining time is derived from a `Date` rather than counted down in a
    /// variable: a `Timer` does not fire while the Mac is asleep, so a lid closed
    /// mid-prompt used to wake to a panel frozen at "3s" that never expired.
    private func startPromptTimer() {
        // Nothing should be able to leave two of these running, but an orphaned
        // 1 Hz timer here answers a question the user never saw.
        countdownTimer?.invalidate()

        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      case .meetingDetected(let app, _) = self.phase,
                      let deadline = self.promptDeadline else { return }
                let remaining = MeetingPromptPolicy.remainingSeconds(until: deadline)
                guard remaining > 0 else { return self.expirePrompt() }
                self.phase = .meetingDetected(app: app, secondsRemaining: remaining)
                self.prompt.update(secondsRemaining: remaining)
            }
        }
        countdownTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Ran out with nobody there. Take the panel away and record nothing — a
    /// question nobody answered is not a yes.
    ///
    /// Not remembered as a decline: "I wasn't at my desk" is not "no", so if the
    /// call is somehow re-detected the user gets asked again.
    private func expirePrompt() {
        if let meeting = pendingMeeting {
            Log.detection.notice("prompt for \(meeting.displayName, privacy: .public) expired unanswered")
        }
        dismissPrompt()
    }

    func acceptPendingMeeting() {
        guard let meeting = pendingMeeting else { return }
        dismissPrompt()
        startRecording(
            detectedApp: meeting.app.displayName,
            meetingKind: meeting.app.kind.rawValue,
            stopWhenCallEnds: true
        )
    }

    func declinePendingMeeting() {
        if let meeting = pendingMeeting {
            declinedMeetingKey = meeting.promptKey
            Log.detection.notice("declined \(meeting.displayName, privacy: .public)")
        }
        dismissPrompt()
    }

    /// The one way the prompt comes down. Panel, timer, deadline and pending
    /// meeting go together so they cannot drift apart — every bug this area has
    /// had was one of the four outliving the others.
    private func dismissPrompt() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        promptDeadline = nil
        pendingMeeting = nil
        prompt.hide()
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

    func startRecording(
        detectedApp: String? = nil,
        meetingKind: String? = nil,
        /// Whether detection should stop this recording when the call ends.
        /// True only for a recording started from the detection panel: the user
        /// answered a question about *that* call, so that call ending is where
        /// the recording belongs. A manual Start is never ours to end.
        stopWhenCallEnds: Bool = false
    ) {
        guard session == nil, !isStarting else { return }
        recordingFollowsDetectedCall = stopWhenCallEnds
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
        recordingFollowsDetectedCall = false
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
