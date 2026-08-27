import AVFoundation
import Foundation

/// Live state of a recording, polled by the UI for meters and the elapsed timer.
public struct RecordingStatus: Sendable, Equatable {
    public var micLevel: Float = 0
    public var systemLevel: Float = 0
    public var micActive: Bool = false
    public var systemActive: Bool = false
    public var duration: TimeInterval = 0
    /// Set when one stream failed but the other kept going, so the UI can say
    /// "recording, but only your microphone" rather than implying all is well.
    public var warning: String?

    public init() {}
}

/// Runs both capture streams for one meeting and owns its metadata.
///
/// Partial capture is treated as success on purpose: if system audio fails
/// because the user hasn't granted the permission, recording your own side is
/// still far better than recording nothing. What matters is that the failure is
/// visible rather than silent.
public final class RecordingSession {
    public let paths: MeetingPaths
    public private(set) var metadata: MeetingMetadata

    private let store: MeetingStore
    private let mic = MicRecorder()
    private let systemTap = SystemAudioTap()
    private var watchdogTimer: DispatchSourceTimer?
    private var watchdogs: [AudioStream: StreamWatchdog] = [:]

    public private(set) var isRecording = false

    public init(
        store: MeetingStore = .shared,
        detectedApp: String? = nil,
        meetingKind: String? = nil
    ) throws {
        self.store = store
        (self.metadata, self.paths) = try store.createMeeting(
            detectedApp: detectedApp,
            meetingKind: meetingKind
        )
    }

    // MARK: Control

    /// Starts both streams. Throws only if *neither* could start.
    ///
    /// This blocks, sometimes for a long time: `AudioHardwareCreateProcessTap`
    /// does not return until the user has answered the audio-capture TCC prompt,
    /// which on a first run can be minutes. Never call it on the main actor —
    /// `AppCoordinator` runs it on a background task for exactly this reason.
    public func start(captureMicrophone: Bool = true, captureSystemAudio: Bool = true) throws {
        guard !isRecording else { return }

        if captureMicrophone {
            do {
                try mic.start(writingTo: paths.micAudio)
                metadata.micStartedAt = Date()
                metadata.hasMicAudio = true
            } catch {
                metadata.micError = error.localizedDescription
                Log.audio.error("mic capture unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }

        if captureSystemAudio {
            do {
                try systemTap.start(writingTo: paths.systemAudio)
                metadata.systemStartedAt = Date()
                metadata.hasSystemAudio = true
            } catch {
                metadata.systemAudioError = error.localizedDescription
                Log.audio.error("system capture unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }

        guard metadata.hasMicAudio || metadata.hasSystemAudio else {
            // Nothing captured at all: don't leave an empty directory behind.
            try? store.delete(id: metadata.id)
            throw AudioCaptureError.conversionFailed(
                metadata.micError ?? metadata.systemAudioError ?? "no audio source available"
            )
        }

        // Anchor the meeting at whichever stream opened first, so `duration`
        // covers everything that was actually captured.
        metadata.startedAt = [metadata.micStartedAt, metadata.systemStartedAt]
            .compactMap { $0 }
            .min() ?? Date()
        metadata.status = .recording
        try? store.save(metadata)

        isRecording = true
        startWatchdog()

        Log.audio.info("recording \(self.metadata.id, privacy: .public) mic=\(self.metadata.hasMicAudio, privacy: .public) system=\(self.metadata.hasSystemAudio, privacy: .public)")
    }

    @discardableResult
    public func stop() -> MeetingMetadata {
        guard isRecording else { return metadata }
        isRecording = false

        watchdogTimer?.cancel()
        watchdogTimer = nil

        mic.stop()
        systemTap.stop()

        metadata.endedAt = Date()
        metadata.status = .awaitingTranscription

        // A stream that ran but produced silence is a failure that would
        // otherwise show up only as a mysteriously empty transcript.
        if metadata.hasMicAudio, mic.peak < ResamplingRecorder.silenceThreshold {
            metadata.micError = "Microphone recorded silence — check the input device and its volume."
            Log.audio.warning("mic stream was silent for \(self.metadata.id, privacy: .public)")
        }
        if metadata.hasSystemAudio, systemTap.peak < ResamplingRecorder.silenceThreshold {
            metadata.systemAudioError = "System audio recorded silence — nothing was playing, or output is muted."
            Log.audio.warning("system stream was silent for \(self.metadata.id, privacy: .public)")
        }

        try? store.save(metadata)
        Log.audio.info("stopped \(self.metadata.id, privacy: .public) after \(Int(self.metadata.duration), privacy: .public)s")
        return metadata
    }

    // MARK: Status

    public func status() -> RecordingStatus {
        var status = RecordingStatus()
        status.micActive = mic.isRunning
        status.systemActive = systemTap.isRunning
        status.micLevel = ResamplingRecorder.meterScale(mic.level)
        status.systemLevel = ResamplingRecorder.meterScale(systemTap.level)
        // Captured audio, not wall clock. A stream that died mid-meeting used to
        // leave this counting cheerfully upwards while nothing was being
        // written, which is the one thing the elapsed time is there to show.
        status.duration = max(mic.duration, systemTap.duration)

        if isRecording {
            if !status.micActive && status.systemActive {
                status.warning = "Microphone not captured — your side won't be transcribed."
            } else if status.micActive && !status.systemActive {
                status.warning = "System audio not captured — only your side will be transcribed."
            } else if let gap = captureGap(at: status.duration) {
                status.warning = gap
            }
        }
        return status
    }

    /// Warns when captured audio has fallen behind the clock.
    ///
    /// Restarting a dead stream costs a seam, and enough of them mean the
    /// recording no longer covers the meeting. The user is the only one who can
    /// act on that — by fixing the device, or by knowing not to rely on this
    /// recording — and only while there is still a meeting left to fix it in.
    ///
    /// The allowance is deliberately loose. A couple of restarts is a few
    /// seconds and not worth a banner; a minute missing is.
    static let captureGapTolerance: TimeInterval = 60

    private func captureGap(at captured: TimeInterval) -> String? {
        let elapsed = Date().timeIntervalSince(metadata.startedAt)
        let missing = elapsed - captured
        guard missing > Self.captureGapTolerance else { return nil }
        return "Audio capture has dropped \(Int(missing / 60)) min — check your input and output devices."
    }

    // MARK: Keeping the streams alive

    /// Restarts either stream once it stops producing audio.
    ///
    /// This used to watch only for a change of default output device, which
    /// strands the aggregate device the system tap is built on. That is a real
    /// failure and it is not the only one: the mic engine stops on any audio
    /// configuration change, and the tap can be lost without the *default*
    /// device changing at all. Both of those leave a stream that reports itself
    /// as running while writing nothing.
    ///
    /// See ``StreamWatchdog`` for why the test is captured seconds rather than
    /// any particular cause.
    private func startWatchdog() {
        let now = Date()
        watchdogs = [
            .microphone: StreamWatchdog(startedAt: metadata.micStartedAt ?? now),
            .system: StreamWatchdog(startedAt: metadata.systemStartedAt ?? now),
        ]

        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "dev.freewhisper.stream-watchdog")
        )
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.isRecording else { return }
            self.checkStreams()
        }
        watchdogTimer = timer
        timer.resume()
    }

    private func checkStreams() {
        if metadata.hasMicAudio,
           watchdogs[.microphone]?.shouldRestart(
               captured: mic.duration,
               forced: mic.needsRestart
           ) == true {
            restart(.microphone)
        }

        if metadata.hasSystemAudio,
           watchdogs[.system]?.shouldRestart(
               captured: systemTap.duration,
               forced: systemTap.needsRestart
           ) == true {
            restart(.system)
        }
    }

    /// Rebuilds one capture stream, continuing into a new segment file.
    ///
    /// A new file rather than the original, because the piece already on disk is
    /// finished and its header says how long it is. The name carries the offset
    /// in seconds from the moment *this stream* opened — the clock its own
    /// timestamps are on, which is what lets ``TranscriptionPipeline`` put the
    /// pieces back in the right place.
    private func restart(_ stream: AudioStream) {
        let origin = (stream == .microphone ? metadata.micStartedAt : metadata.systemStartedAt)
            ?? metadata.startedAt
        let captured = stream == .microphone ? mic.duration : systemTap.duration
        let url = paths.audioSegment(stream, restartedAt: Date().timeIntervalSince(origin))

        Log.audio.notice("""
            restarting \(stream.rawValue, privacy: .public) capture into \
            \(url.lastPathComponent, privacy: .public) after \
            \(Int(captured), privacy: .public)s captured
            """)

        do {
            switch stream {
            case .microphone:
                mic.stop()
                try mic.start(writingTo: url)
            case .system:
                systemTap.stop()
                try systemTap.start(writingTo: url)
            }
        } catch {
            // Not fatal, and not final: the watchdog keeps trying on a widening
            // backoff, so a device that comes back is picked up again. Record it
            // so a meeting that never recovered says why.
            Log.audio.error("""
                could not restart \(stream.rawValue, privacy: .public) capture: \
                \(error.localizedDescription, privacy: .public)
                """)
            let message = "\(stream.displayName) stopped mid-recording and could not be restarted."
            switch stream {
            case .microphone: metadata.micError = message
            case .system: metadata.systemAudioError = message
            }
            try? store.save(metadata)
        }
    }
}
