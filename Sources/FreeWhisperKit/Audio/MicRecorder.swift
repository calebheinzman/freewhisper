import AVFoundation
import Foundation

/// Captures the default input device to a 16 kHz mono WAV.
///
/// Kept as its own stream rather than mixed with system audio: having "you" and
/// "everyone else" separated at capture time makes speaker attribution for your
/// own turns exact, and leaves diarization with only the remote channel to
/// solve.
public final class MicRecorder {
    private let engine = AVAudioEngine()
    private var recorder: ResamplingRecorder?
    private var configurationObserver: (any NSObjectProtocol)?

    // Retained past stop() so callers can still ask "did this stream actually
    // capture anything?" after the recorder has been torn down.
    private var finalPeak: Float = 0
    /// Seconds captured by recorders that have already been closed. The live
    /// recorder's own duration is added on top, so a restart continues the count
    /// rather than dropping it back to zero.
    private var capturedBeforeRestart: TimeInterval = 0

    public private(set) var isRunning = false

    /// Set when the audio configuration changed underneath the engine. The
    /// session polls this and rebuilds the stream into a new segment.
    public private(set) var needsRestart = false

    public init() {}

    deinit { stop() }

    public var level: Float { recorder?.level ?? 0 }
    public var peak: Float { max(finalPeak, recorder?.peak ?? 0) }
    public var duration: TimeInterval { capturedBeforeRestart + (recorder?.duration ?? 0) }

    public func start(writingTo url: URL) throws {
        guard !isRunning else { return }
        needsRestart = false

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        // A zero sample rate means the HAL handed us a null input device, which
        // is what happens when microphone permission is missing or there is no
        // input hardware at all.
        guard format.sampleRate > 0 else {
            throw AudioCaptureError.noMicrophoneAvailable
        }

        let recorder = try ResamplingRecorder(url: url, sourceFormat: format)
        self.recorder = recorder

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            do {
                try recorder.write(buffer)
            } catch {
                Log.audio.error("mic write failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        observeConfigurationChanges()
        engine.prepare()
        try engine.start()
        isRunning = true

        Log.audio.info("mic running: \(format.sampleRate, privacy: .public)Hz x\(format.channelCount, privacy: .public) -> \(url.lastPathComponent, privacy: .public)")
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false

        stopObservingConfigurationChanges()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        finalPeak = max(finalPeak, recorder?.peak ?? 0)
        capturedBeforeRestart += recorder?.duration ?? 0
        recorder?.close()
        recorder = nil
    }

    // MARK: Configuration changes

    /// `AVAudioEngine` stops itself when the input hardware changes underneath
    /// it — a Bluetooth headset connecting, a dock arriving, a sample rate
    /// changing — and it does not come back on its own. The tap installed on the
    /// old configuration is dead, and nothing about the engine says so from the
    /// outside: `isRunning` is our flag, not its state, so the session went on
    /// believing it was recording. That is how an 88-minute meeting produced 43
    /// minutes of microphone audio and looked, from the transcript, like a
    /// 42-minute limit somewhere in ASR.
    ///
    /// Restarting the engine in place is not enough. The input format may have
    /// changed, and both the tap and the resampler were built for the old one,
    /// so the whole stream has to be rebuilt — including the file, since the
    /// piece already on disk is finished. Flag it and let ``RecordingSession``
    /// do that, which is where the meeting's file layout is known.
    private func observeConfigurationChanges() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self, self.isRunning else { return }
            Log.audio.notice("audio configuration changed; mic stream needs restart")
            self.needsRestart = true
        }
    }

    private func stopObservingConfigurationChanges() {
        guard let configurationObserver else { return }
        NotificationCenter.default.removeObserver(configurationObserver)
        self.configurationObserver = nil
    }
}
