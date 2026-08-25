import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Captures everything the Mac is playing, via a CoreAudio process tap.
///
/// This is a *global* tap rather than a per-process one, and that is a
/// deliberate trade. Slack plays huddle audio from `Slack Helper (Renderer)`
/// and Chrome plays Meet audio from a renderer process, so targeting an app by
/// PID means chasing helper processes that come and go mid-call. A global tap
/// cannot miss the meeting. The cost is that it also captures Spotify and
/// notification chimes.
///
/// Requires `NSAudioCaptureUsageDescription` and the user's approval; the first
/// `start()` on a fresh install is what raises the prompt.
public final class SystemAudioTap {
    private let queue = DispatchQueue(label: "dev.freewhisper.system-tap", qos: .userInitiated)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var recorder: ResamplingRecorder?
    private var deviceChangeListener: AudioObjectPropertyListenerBlock?

    public private(set) var isRunning = false
    /// Set when the default output device changes mid-recording. The session
    /// polls this and restarts the tap onto the new device.
    public private(set) var needsRestart = false

    public init() {}

    deinit { stop() }

    // Retained past stop() so callers can still ask "did this stream actually
    // capture anything?" after the recorder has been torn down.
    private var finalPeak: Float = 0
    private var finalDuration: TimeInterval = 0

    public var level: Float { recorder?.level ?? 0 }
    public var peak: Float { recorder?.peak ?? finalPeak }
    public var duration: TimeInterval { recorder?.duration ?? finalDuration }

    // MARK: Lifecycle

    public func start(writingTo url: URL) throws {
        guard !isRunning else { return }
        needsRestart = false

        try createTap()
        let format = try tapFormat()
        try createAggregateDevice()

        let recorder = try ResamplingRecorder(url: url, sourceFormat: format)
        self.recorder = recorder

        try startIOProc(sourceFormat: format, recorder: recorder)
        observeDefaultOutputDeviceChanges()

        isRunning = true
        Log.audio.info("system tap running: \(format.sampleRate, privacy: .public)Hz x\(format.channelCount, privacy: .public) -> \(url.lastPathComponent, privacy: .public)")
    }

    public func stop() {
        guard isRunning || tapID.isValid || aggregateDeviceID.isValid else { return }
        isRunning = false

        stopObservingDefaultOutputDevice()

        if aggregateDeviceID.isValid {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            if let ioProcID {
                AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
                self.ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }

        if tapID.isValid {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }

        // Drain the audio queue so no in-flight buffer writes to a closed file.
        queue.sync {}

        finalPeak = max(finalPeak, recorder?.peak ?? 0)
        finalDuration += recorder?.duration ?? 0
        recorder?.close()
        recorder = nil
    }

    // MARK: Setup

    private func createTap() throws {
        // Exclude ourselves so a dictation chime or preview playback can never
        // feed back into the meeting recording.
        let excluded = ownAudioProcessObject().map { [$0] } ?? []
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.name = "FreeWhisper"
        description.isPrivate = true
        // Never mute what we tap — the user still needs to hear the call.
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr, newTapID.isValid else {
            throw AudioCaptureError.tapCreationFailed(status)
        }
        tapID = newTapID
        tapUUID = description.uuid
    }

    private var tapUUID = UUID()

    private func tapFormat() throws -> AVAudioFormat {
        var description: AudioStreamBasicDescription = try tapID.read(
            AudioObjectPropertyAddress(kAudioTapPropertyFormat)
        )
        guard let format = AVAudioFormat(streamDescription: &description) else {
            throw AudioCaptureError.invalidSourceFormat("tap stream description")
        }
        return format
    }

    private func createAggregateDevice() throws {
        // The aggregate needs a real output device as its main sub-device; a
        // tap on its own is not a valid device.
        let outputDeviceID: AudioDeviceID = try AudioObjectID.system.read(
            AudioObjectPropertyAddress(kAudioHardwarePropertyDefaultSystemOutputDevice)
        )
        let outputUID = try outputDeviceID.readString(
            AudioObjectPropertyAddress(kAudioDevicePropertyDeviceUID)
        )

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "FreeWhisper Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            // Private keeps it out of the user's Sound settings and Audio MIDI Setup.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                ]
            ],
        ]

        var newDeviceID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newDeviceID)
        guard status == noErr, newDeviceID.isValid else {
            throw AudioCaptureError.aggregateDeviceFailed(status)
        }
        aggregateDeviceID = newDeviceID
    }

    private func startIOProc(sourceFormat: AVAudioFormat, recorder: ResamplingRecorder) throws {
        var procID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(
            &procID, aggregateDeviceID, queue
        ) { [weak recorder] _, inputData, _, _, _ in
            guard let recorder else { return }
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                bufferListNoCopy: inputData,
                deallocator: nil
            ) else { return }

            do {
                try recorder.write(buffer)
            } catch {
                Log.audio.error("system tap write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard status == noErr, let procID else {
            throw AudioCaptureError.ioProcFailed(status)
        }
        ioProcID = procID

        status = AudioDeviceStart(aggregateDeviceID, procID)
        guard status == noErr else {
            throw AudioCaptureError.ioProcFailed(status)
        }
    }

    // MARK: Output device changes

    /// The aggregate device is bound to whichever output device was default when
    /// it was built. Plugging in headphones mid-meeting silently strands it on
    /// the old device, so watch for the switch and flag a restart.
    private func observeDefaultOutputDeviceChanges() {
        var address = AudioObjectPropertyAddress(kAudioHardwarePropertyDefaultSystemOutputDevice)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.isRunning else { return }
            Log.audio.notice("default output device changed; system tap needs restart")
            self.needsRestart = true
        }
        deviceChangeListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID.system, &address, queue, listener)
    }

    private func stopObservingDefaultOutputDevice() {
        guard let listener = deviceChangeListener else { return }
        var address = AudioObjectPropertyAddress(kAudioHardwarePropertyDefaultSystemOutputDevice)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID.system, &address, queue, listener)
        deviceChangeListener = nil
    }

    // MARK: Helpers

    private func ownAudioProcessObject() -> AudioObjectID? {
        var pid = getpid()
        var address = AudioObjectPropertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID.system, &address,
            UInt32(MemoryLayout<pid_t>.size), &pid,
            &size, &objectID
        )
        // Absent until the process has actually touched audio, which is fine.
        guard status == noErr, objectID.isValid else { return nil }
        return objectID
    }
}
