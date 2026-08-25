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
    case transcribing
    case failed(String)
}

/// Global-hotkey voice-to-text into whatever app the user is in.
@Observable
@MainActor
final class DictationController {
    private(set) var state: DictationState = .idle
    private(set) var level: Float = 0

    @ObservationIgnored private let recorder = DictationRecorder()
    @ObservationIgnored private let chord = ChordMonitor()
    @ObservationIgnored private var levelTimer: Timer?
    @ObservationIgnored private var safetyTimer: Timer?
    @ObservationIgnored private var isRegistered = false

    /// Whether the built-in ⌘⎋ chord is listening. False means Accessibility is
    /// missing or the user turned the chord off, and the only way in is a custom
    /// shortcut — which may well be unset.
    var chordIsActive: Bool { chord.isActive }

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
        guard chordEnabled else {
            chord.stop()
            return
        }
        chord.onStart = { [weak self] in self?.beginListening() }
        chord.onStop = { [weak self] in self?.finishListening() }
        chord.start()
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
        guard state == .idle else { return }

        // An engine whose weights are still downloading takes minutes to answer,
        // which from the outside is indistinguishable from a broken hotkey. Say
        // so instead of recording into a stall.
        guard ModelSetupModel.shared.defaultsAreReady else {
            state = .failed("Speech model is still downloading.")
            clearAfterDelay()
            return
        }

        do {
            try recorder.start()
            state = .listening
            startLevelPolling()
            startSafetyTimer()
        } catch {
            state = .failed(error.localizedDescription)
            Log.dictation.error("could not start dictation: \(error.localizedDescription, privacy: .public)")
            clearAfterDelay()
        }
    }

    private func finishListening() {
        guard state == .listening else { return }
        stopLevelPolling()
        stopSafetyTimer()

        guard let url = recorder.stop() else {
            // Nothing usable — an accidental tap. Say nothing, do nothing.
            state = .idle
            return
        }

        state = .transcribing
        let model = self.model

        Task {
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let (asr, _) = await TranscriptionPipeline.engines(for: model)
                let segments = try await asr.transcribe(url: url, progress: nil)
                let text = segments.map(\.text)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                guard !text.isEmpty else {
                    // Audio loud enough to keep, but no words in it. Worth a
                    // line: from the outside this is indistinguishable from a
                    // hotkey that never fired.
                    Log.dictation.notice("nothing to insert — no speech found in the clip")
                    self.state = .idle
                    return
                }

                try TextInserter.insert(text)
                self.state = .idle
                Log.dictation.info("inserted \(text.count, privacy: .public) characters")
            } catch {
                self.state = .failed(error.localizedDescription)
                Log.dictation.error("dictation failed: \(error.localizedDescription, privacy: .public)")
                self.clearAfterDelay()
            }
        }
    }

    func cancel() {
        stopLevelPolling()
        stopSafetyTimer()
        recorder.cancel()
        state = .idle
    }

    /// Runs the whole pipeline without the hotkey, so a user reporting "nothing
    /// happens" can tell a dead trigger apart from a dead microphone, a missing
    /// model or a refused paste. Records for a fixed few seconds.
    func runSelfTest(seconds: TimeInterval = 4) {
        guard state == .idle else { return }
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

    private func clearAfterDelay() {
        Task {
            try? await Task.sleep(for: .seconds(3))
            if case .failed = self.state { self.state = .idle }
        }
    }
}
