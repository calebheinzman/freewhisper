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

    // Retained past stop() so callers can still ask "did this stream actually
    // capture anything?" after the recorder has been torn down.
    private var finalPeak: Float = 0
    private var finalDuration: TimeInterval = 0

    public private(set) var isRunning = false

    public init() {}

    deinit { stop() }

    public var level: Float { recorder?.level ?? 0 }
    public var peak: Float { recorder?.peak ?? finalPeak }
    public var duration: TimeInterval { recorder?.duration ?? finalDuration }

    public func start(writingTo url: URL) throws {
        guard !isRunning else { return }

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

        engine.prepare()
        try engine.start()
        isRunning = true

        Log.audio.info("mic running: \(format.sampleRate, privacy: .public)Hz x\(format.channelCount, privacy: .public) -> \(url.lastPathComponent, privacy: .public)")
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        finalPeak = recorder?.peak ?? 0
        finalDuration = recorder?.duration ?? 0
        recorder?.close()
        recorder = nil
    }
}
