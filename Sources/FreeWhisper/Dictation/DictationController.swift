import AppKit
import FreeWhisperKit
import KeyboardShortcuts
import Observation

extension KeyboardShortcuts.Name {
    static let dictate = Self("dictate")
}

enum DictationMode: String, CaseIterable, Identifiable {
    /// Hold the key, speak, release. Best when you know what you want to say.
    case pushToTalk
    /// Press to start, press again to stop. Best for longer dictation.
    case toggle

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pushToTalk: "Hold to talk"
        case .toggle: "Press to start, press to stop"
        }
    }
}

enum DictationState: Equatable {
    case idle
    case listening
    /// Weights are loading or downloading. Separate from `.transcribing` because
    /// a cold load can run for minutes while inference runs for a second, and
    /// showing "Transcribing…" for both made a working model look hung.
    case preparing(String)
    case transcribing
    case cancelled
    case failed(String)

    /// Whether a dictation is actually under way. `.cancelled` and `.failed` are
    /// transient labels on an app that is otherwise idle, so they read as not
    /// busy — locking the user out of dictation for the second they sit on
    /// screen is how "the hotkey didn't work" bug reports get written.
    var isBusy: Bool {
        switch self {
        case .listening, .preparing, .transcribing: true
        case .idle, .cancelled, .failed: false
        }
    }
}

/// Global-hotkey voice-to-text into whatever app the user is in.
@Observable
@MainActor
final class DictationController {
    private(set) var state: DictationState = .idle
    private(set) var level: Float = 0

    @ObservationIgnored private let recorder = DictationRecorder()
    /// Shared with the chord monitor because the event tap has to know whether
    /// there is a dictation to cancel, synchronously, from inside its callback.
    @ObservationIgnored private let activity = DictationActivity()
    @ObservationIgnored private lazy var chord = ChordMonitor(activity: activity)
    @ObservationIgnored private var levelTimer: Timer?
    @ObservationIgnored private var safetyTimer: Timer?
    @ObservationIgnored private var isRegistered = false
    /// Which run is currently on screen, so a transcription that finishes after
    /// the user cancelled — or after they started another one — can tell.
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var transcriptionTask: Task<Void, Never>?
    /// Retained so starting a new dictation can dismiss a lingering `.cancelled`
    /// or `.failed` label instead of racing it.
    @ObservationIgnored private var clearTask: Task<Void, Never>?

    /// Whether the built-in ⌘⎋ chord is listening. False means Accessibility is
    /// missing or the user turned the chord off, and the only way in is a custom
    /// shortcut — which may well be unset.
    ///
    /// The `chordEnabled` clause matters: the tap can also be up purely so
    /// Escape can cancel, and reporting that as a working ⌘⎋ would tell the user
    /// to press a key combination that deliberately does nothing.
    var chordIsActive: Bool { chordEnabled && chord.isActive }

    var chordEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: SettingsKeys.chordEnabled) }
        set {
            UserDefaults.standard.set(newValue, forKey: SettingsKeys.chordEnabled)
            syncChord()
        }
    }

    /// The custom shortcut is genuinely optional now that the chord ships as the
    /// default, so "none" is a legitimate state rather than a broken one.
    var customShortcut: KeyboardShortcuts.Shortcut? {
        KeyboardShortcuts.getShortcut(for: .dictate)
    }

    /// No way to trigger dictation at all. Worth surfacing: the previous version
    /// of this app could reach exactly this state and said nothing.
    var hasNoTrigger: Bool { !chordIsActive && customShortcut == nil }

    var mode: DictationMode {
        get {
            DictationMode(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.dictationMode) ?? "")
                ?? .pushToTalk
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKeys.dictationMode)
            registerShortcut()
        }
    }

    /// Defaults to Parakeet rather than Whisper: it is roughly eight times
    /// faster on the same clip, and for dictation latency matters more than the
    /// last few points of accuracy.
    var model: ModelCatalog.Model {
        get {
            ModelCatalog.transcriber(
                id: UserDefaults.standard.string(forKey: SettingsKeys.dictationModel),
                or: ModelCatalog.defaultDictationTranscriber
            )
        }
        set { UserDefaults.standard.set(newValue.id, forKey: SettingsKeys.dictationModel) }
    }

    func start() {
        guard !isRegistered else { return }
        isRegistered = true

        // No default is written into the shortcut store any more. The previous
        // version installed ⌃⌥Space behind a one-shot "installed" flag, so when
        // the settings recorder cleared the binding — which it does whenever its
        // text field empties — dictation became permanently unreachable with no
        // way back and nothing on screen saying so. The chord is code, not
        // stored state, so it cannot be lost.
        syncChord()
        registerShortcut()
    }

    /// Re-create the event tap if it isn't running.
    ///
    /// `CGEvent.tapCreate` fails silently without Accessibility, and `syncChord`
    /// only ever ran once at launch — so granting the permission afterwards left
    /// the chord dead until the next relaunch, with the menu bar cheerfully
    /// reporting ⌘⎋ as the active trigger. Called whenever the app is activated,
    /// which is when the user comes back from System Settings.
    func rearmChordIfNeeded() {
        guard chordEnabled, !chord.isActive else { return }
        syncChord()
    }

    private func syncChord() {
        chord.onStart = { [weak self] in self?.beginListening() }
        chord.onStop = { [weak self] in self?.finishListening() }
        chord.onCancel = { [weak self] in self?.cancel() }

        guard chordEnabled else {
            // The tap comes down, but only while nothing is running. Turning the
            // chord off is the user declining a system-wide keyboard tap, and
            // honouring that is worth more than Escape-cancel — which they can
            // still reach from the HUD, and which `armCancelTapIfNeeded` puts
            // back for the duration of each dictation.
            if !state.isBusy { chord.stop() }
            return
        }
        chord.armingEnabled = true
        chord.start()
    }

    /// Bring the tap up for the length of one dictation when the chord is off.
    ///
    /// Without this, a user who turned ⌘⎋ off has no Escape at all, because the
    /// tap that would see it does not exist. It arms with `armingEnabled` false,
    /// so ⌘⎋ neither starts a dictation nor is withheld from the app underneath
    /// — the tap is there to notice one key and nothing else.
    ///
    /// Accessibility needs no separate handling: `CGEvent.tapCreate` and the
    /// `AXIsProcessTrusted()` that `TextInserter` requires to type the result
    /// gate on the same permission, so Escape-cancel is available exactly when
    /// dictation itself is.
    private func armCancelTapIfNeeded() {
        guard !chordEnabled, !chord.isActive else { return }
        chord.armingEnabled = false
        chord.start()
    }

    /// Take the cancel-only tap back down once there is nothing left to cancel.
    private func releaseCancelTapIfNeeded() {
        guard !chordEnabled, chord.isActive else { return }
        chord.stop()
    }

    private func registerShortcut() {
        // Re-registering replaces the previous handlers, which is how switching
        // between hold and toggle takes effect without a relaunch.
        KeyboardShortcuts.onKeyDown(for: .dictate) { [weak self] in
            guard let self else { return }
            switch self.mode {
            case .pushToTalk: self.beginListening()
            case .toggle: self.toggle()
            }
        }
        KeyboardShortcuts.onKeyUp(for: .dictate) { [weak self] in
            guard let self, self.mode == .pushToTalk else { return }
            self.finishListening()
        }
    }

    // MARK: Control

    func toggle() {
        if case .listening = state {
            finishListening()
        } else {
            beginListening()
        }
    }

    private func beginListening() {
        // Not `state == .idle`: cancelling in order to immediately redo is the
        // whole point of a cancel, and a `.cancelled` label still on screen must
        // not lock the user out of the retry.
        guard !state.isBusy else { return }
        clearTask?.cancel()
        clearTask = nil

        // An engine whose weights are still downloading takes minutes to answer,
        // which from the outside is indistinguishable from a broken hotkey. Say
        // so instead of recording into a stall.
        guard ModelSetupModel.shared.defaultsAreReady else {
            fail(with: "Speech model is still downloading.")
            return
        }

        do {
            try recorder.start()
            // Only once the microphone is actually open: from here on Escape
            // means "stop this", which had better refer to something real.
            generation = activity.begin()
            armCancelTapIfNeeded()
            state = .listening
            startLevelPolling()
            startSafetyTimer()
        } catch {
            Log.dictation.error("could not start dictation: \(error.localizedDescription, privacy: .public)")
            fail(with: error.localizedDescription)
        }
    }

    private func finishListening() {
        guard state == .listening else { return }
        stopLevelPolling()
        stopSafetyTimer()

        guard let url = recorder.stop() else {
            // Nothing usable — an accidental tap. Say nothing, do nothing.
            finish(generation)
            return
        }

        state = .transcribing
        let model = self.model
        let generation = self.generation

        // Retained so `cancel()` can ask the engine to stop. That request is a
        // courtesy and little more: of the engines here only the cloud one,
        // which is URLSession all the way down, actually notices. Parakeet — the
        // dictation default — is a single un-checkpointed `await`, and the
        // timeout below is a task group, which waits for its children. So a
        // cancelled run keeps burning CPU until it finishes on its own. What
        // makes cancelling *correct* is the generation guard on every exit
        // below; this only sometimes makes it faster.
        transcriptionTask = Task {
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let (asr, _) = await TranscriptionPipeline.engines(for: model)

                // Loading is deliberately outside the timeout below. A first-ever
                // load of Whisper large-v3 compiles CoreML for the Neural Engine
                // and takes about 170 seconds on this hardware; Distil-Whisper
                // took 774. Both blow any bound worth putting on inference, so
                // timing them together meant the first dictation on a newly
                // chosen model was guaranteed to "fail" after two minutes of
                // saying "Transcribing…". Warm loads return in well under a
                // second — `prepare` is single-flighted and idempotent — so this
                // costs nothing in the common case.
                let name = model.name
                await MainActor.run {
                    guard self.activity.isRunning(generation) else { return }
                    self.state = .preparing("Loading \(name)")
                }
                try await asr.prepare(progress: { [weak self] update in
                    Task { @MainActor [weak self] in
                        guard let self, self.activity.isRunning(generation) else { return }
                        switch update {
                        case .downloadingModel(let model, _): self.state = .preparing("Downloading \(model)")
                        case .loadingModel(let model): self.state = .preparing("Loading \(model)")
                        default: break
                        }
                    }
                })

                await MainActor.run {
                    guard self.activity.isRunning(generation) else { return }
                    self.state = .transcribing
                }
                let segments = try await Self.withTimeout(seconds: Self.transcribeTimeout) {
                    try await asr.transcribe(url: url, progress: nil)
                }
                let text = segments.map(\.text)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                // The one guard that makes cancelling safe. Not `Task.isCancelled`
                // — the on-device engines never check it, so it can still be
                // false on a run the user gave up on. Not `state != .idle` —
                // by now a *new* dictation may be listening, and this text does
                // not belong to it. Only "is the run I started still the run the
                // user is waiting on" answers both at once.
                guard self.activity.isRunning(generation) else {
                    Log.dictation.notice("discarded \(text.count, privacy: .public) characters from a cancelled dictation")
                    return
                }

                guard !text.isEmpty else {
                    // Audio loud enough to keep, but no words in it. Worth a
                    // line: from the outside this is indistinguishable from a
                    // hotkey that never fired.
                    Log.dictation.notice("nothing to insert — no speech found in the clip")
                    self.finish(generation)
                    return
                }

                try TextInserter.insert(text)
                self.finish(generation)
                Log.dictation.info("inserted \(text.count, privacy: .public) characters")
            } catch {
                // The same gate on the failure path. Cancelling the task makes
                // the timeout's sleep throw, so a cancelled run arrives here
                // looking exactly like a genuine fault — and must not raise a
                // "Dictation failed" HUD over a dictation the user ended.
                guard self.activity.isRunning(generation) else { return }
                self.activity.end(generation)
                self.transcriptionTask = nil
                Log.dictation.error("dictation failed: \(error.localizedDescription, privacy: .public)")
                self.fail(with: error.localizedDescription)
            }
        }
    }

    /// Ends a run cleanly and returns to idle, but only if it is still the
    /// current one — see the guards in `finishListening`.
    private func finish(_ generation: UInt64) {
        activity.end(generation)
        transcriptionTask = nil
        releaseCancelTapIfNeeded()
        state = .idle
    }

    private func fail(with message: String) {
        let failure = DictationState.failed(message)
        state = failure
        clearAfterDelay(failure, after: Self.failureDwell)
    }

    /// Generous, because it covers a cold model load on a slow disk as well as
    /// the inference itself. It exists to bound the failure, not to be hit.
    static let transcribeTimeout: TimeInterval = 120

    /// Fails instead of hanging.
    ///
    /// Recording has a safety timer but transcription had nothing, so anything
    /// that never returned left the HUD reading "Transcribing…" forever with no
    /// way back except quitting the app. A dictation that takes two minutes is
    /// already a failure; the user should be told so and released.
    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw DictationTimeout()
            }
            guard let result = try await group.next() else { throw DictationTimeout() }
            group.cancelAll()
            return result
        }
    }

    /// Abandon whatever is running: the clip is deleted, and nothing is typed.
    ///
    /// Reached from a bare Escape while a dictation is up, and from the HUD's
    /// cancel button.
    func cancel() {
        guard state.isBusy else { return }

        // Idempotent by design. When Escape triggered this, the event tap has
        // already claimed the run — synchronously, before it decided the key was
        // worth swallowing — and that claim is what stops a transcription
        // finishing in the same instant from pasting anyway.
        activity.claimCancel()

        stopLevelPolling()
        stopSafetyTimer()
        // A no-op while transcribing: the recorder guards on `isRecording`, and
        // by then the clip belongs to the transcription task's `defer`.
        recorder.cancel()
        transcriptionTask?.cancel()
        transcriptionTask = nil

        state = .cancelled
        clearAfterDelay(.cancelled, after: Self.cancelledDwell)
        Log.dictation.notice("dictation cancelled")
    }

    /// Runs the whole pipeline without the hotkey, so a user reporting "nothing
    /// happens" can tell a dead trigger apart from a dead microphone, a missing
    /// model or a refused paste. Records for a fixed few seconds.
    func runSelfTest(seconds: TimeInterval = 4) {
        guard !state.isBusy else { return }
        beginListening()
        guard state == .listening else { return }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            self.finishListening()
        }
    }

    // MARK: Safety

    /// A missed key-up would otherwise leave the recorder running forever. The
    /// tap can be disabled mid-chord by the system, and `reset()` deliberately
    /// forgets the key state when that happens, so the stop event can genuinely
    /// go missing.
    private static let maximumDictationLength: TimeInterval = 120

    private func startSafetyTimer() {
        stopSafetyTimer()
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.maximumDictationLength,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.state == .listening else { return }
                Log.dictation.notice("dictation hit the length ceiling; finishing")
                self.finishListening()
            }
        }
        safetyTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopSafetyTimer() {
        safetyTimer?.invalidate()
        safetyTimer = nil
    }

    // MARK: Level metering

    private func startLevelPolling() {
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.level = self.recorder.level
            }
        }
        levelTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopLevelPolling() {
        levelTimer?.invalidate()
        levelTimer = nil
        level = 0
    }

    /// How long each self-clearing label sits on the HUD. A failure has
    /// something to read; a cancellation only has to register as deliberate.
    private static let failureDwell: TimeInterval = 3
    private static let cancelledDwell: TimeInterval = 1

    /// Clears a transient label, unless something has moved on in the meantime.
    ///
    /// Retained rather than fire-and-forget so `beginListening` can dismiss the
    /// label the instant the user retries — the same shape `ScreenshotHUD` uses
    /// for its auto-dismiss.
    private func clearAfterDelay(_ transient: DictationState, after seconds: TimeInterval) {
        clearTask?.cancel()
        clearTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, self.state == transient else { return }
            // Deliberately not at the moment of cancelling: leaving the tap up
            // for the dwell means it is still there to withhold the key-up that
            // matches the Escape we already withheld.
            self.releaseCancelTapIfNeeded()
            self.state = .idle
        }
    }
}

/// Surfaced to the user as the HUD's failure text, so it says what happened.
struct DictationTimeout: LocalizedError {
    var errorDescription: String? {
        "Transcribing took too long and was stopped. The model may still be loading — try again in a moment."
    }
}
