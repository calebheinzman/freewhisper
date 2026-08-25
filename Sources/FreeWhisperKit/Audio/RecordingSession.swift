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
    private var restartCheckTimer: DispatchSourceTimer?

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
        startWatchingForDeviceChanges()

        Log.audio.info("recording \(self.metadata.id, privacy: .public) mic=\(self.metadata.hasMicAudio, privacy: .public) system=\(self.metadata.hasSystemAudio, privacy: .public)")
    }

    @discardableResult
    public func stop() -> MeetingMetadata {
        guard isRecording else { return metadata }
        isRecording = false

        restartCheckTimer?.cancel()
        restartCheckTimer = nil

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
        status.duration = Date().timeIntervalSince(metadata.startedAt)

        if isRecording {
            if !status.micActive && status.systemActive {
                status.warning = "Microphone not captured — your side won't be transcribed."
            } else if status.micActive && !status.systemActive {
                status.warning = "System audio not captured — only your side will be transcribed."
            }
        }
        return status
    }

    // MARK: Device changes

    /// The aggregate device is pinned to whichever output device existed when it
    /// was created, so switching to headphones mid-call strands it. Rebuild the
    /// system tap onto the new device, leaving the mic stream untouched.
    private func startWatchingForDeviceChanges() {
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "dev.freewhisper.device-watch")
        )
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.isRecording, self.systemTap.needsRestart else { return }
            self.restartSystemTap()
        }
        restartCheckTimer = timer
        timer.resume()
    }

    private func restartSystemTap() {
        Log.audio.notice("restarting system tap after output device change")
        systemTap.stop()

        // Recording continues into a numbered sibling file; the assembler
        // stitches the segments back together by their start timestamps.
        let segmentURL = paths.directory.appendingPathComponent(
            "system-\(Int(Date().timeIntervalSince(metadata.startedAt))).wav"
        )
        do {
            try systemTap.start(writingTo: segmentURL)
        } catch {
            Log.audio.error("could not restart system tap: \(error.localizedDescription, privacy: .public)")
            metadata.systemAudioError = "System audio stopped when the output device changed."
            try? store.save(metadata)
        }
    }
}
