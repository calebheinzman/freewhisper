import AVFoundation
import Foundation

/// Writes an incoming audio stream to a 16 kHz mono WAV, resampling on the fly,
/// and keeps a running signal level for the UI meters.
///
/// Both capture sources feed one of these: the microphone (via AVAudioEngine)
/// and system audio (via a CoreAudio process tap). They arrive in different
/// formats and at different rates, and both come off real-time threads, so all
/// writing happens on the caller's audio queue and only the published level and
/// frame count are lock-protected.
public final class ResamplingRecorder {
    public let url: URL

    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat
    private let sourceFormat: AVAudioFormat
    /// Released by `close()`. AVAudioFile only writes its final header when it
    /// deallocates, so holding it past close leaves a zero-length WAV on disk
    /// for anything that reads the file straight after recording stops.
    private var file: AVAudioFile?

    private let stateLock = NSLock()
    private var _level: Float = 0
    private var _peak: Float = 0
    private var _frameCount: AVAudioFramePosition = 0
    private var _isClosed = false

    public init(url: URL, sourceFormat: AVAudioFormat) throws {
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
            throw AudioCaptureError.invalidSourceFormat(String(describing: sourceFormat))
        }

        let target = AudioFormats.processing
        guard let converter = AVAudioConverter(from: sourceFormat, to: target) else {
            throw AudioCaptureError.converterUnavailable(
                from: String(describing: sourceFormat),
                to: String(describing: target)
            )
        }

        self.url = url
        self.sourceFormat = sourceFormat
        self.targetFormat = target
        self.converter = converter
        self.file = try AVAudioFile(
            forWriting: url,
            settings: AudioFormats.fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    // MARK: Observable state

    /// RMS of the most recent buffer, 0...1. Drives the level meters.
    public var level: Float {
        stateLock.lock(); defer { stateLock.unlock() }
        return _level
    }

    /// Level mapped onto a 0...1 meter scale.
    ///
    /// Speech RMS sits around 0.01–0.1, so a linear bar shows nothing at all for
    /// a normal microphone in a quiet room. Metering in dB over a -60...0 dB
    /// range is what makes the bar actually track someone talking.
    public var meterLevel: Float {
        Self.meterScale(level)
    }

    public static func meterScale(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        let floor: Float = -60
        return max(0, min(1, (decibels - floor) / -floor))
    }

    /// Below roughly -60 dBFS nothing usable was captured — a dead stream
    /// rather than a quiet one.
    public static let silenceThreshold: Float = 0.001

    /// Loudest sample seen so far. A peak of exactly zero after a recording is
    /// the signature of a capture that silently produced nothing.
    public var peak: Float {
        stateLock.lock(); defer { stateLock.unlock() }
        return _peak
    }

    public var duration: TimeInterval {
        stateLock.lock(); defer { stateLock.unlock() }
        return Double(_frameCount) / AudioFormats.sampleRate
    }

    // MARK: Writing

    /// Called from the audio thread. Must not block.
    public func write(_ input: AVAudioPCMBuffer) throws {
        stateLock.lock()
        let closed = _isClosed
        stateLock.unlock()
        guard !closed, let file, input.frameLength > 0 else { return }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        // Slack for the resampler's internal filter delay; it may emit slightly
        // more than the naive ratio suggests.
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024

        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw AudioCaptureError.bufferAllocationFailed
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            // The pull-style API asks repeatedly; hand over this buffer exactly
            // once, then report starvation so it flushes what it has.
            if suppliedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return input
        }

        if let conversionError {
            throw AudioCaptureError.conversionFailed(conversionError.localizedDescription)
        }
        guard status != .error, output.frameLength > 0 else { return }

        try file.write(from: output)
        updateLevels(from: output)
    }

    private func updateLevels(from buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)

        var sumOfSquares: Float = 0
        var peak: Float = 0
        for index in 0..<count {
            let sample = samples[index]
            sumOfSquares += sample * sample
            peak = max(peak, abs(sample))
        }
        let rms = count > 0 ? (sumOfSquares / Float(count)).squareRoot() : 0

        stateLock.lock()
        _level = rms
        _peak = max(_peak, peak)
        _frameCount += AVAudioFramePosition(count)
        stateLock.unlock()
    }

    /// Finalises the WAV header and releases the file. Safe to call more than
    /// once. After this returns, the file on disk is complete and readable.
    ///
    /// Callers must ensure no `write` is in flight on the audio queue — the
    /// capture classes drain their queue before calling this.
    public func close() {
        stateLock.lock()
        guard !_isClosed else { stateLock.unlock(); return }
        _isClosed = true
        _level = 0
        stateLock.unlock()

        file = nil
    }
}

public enum AudioCaptureError: LocalizedError {
    case invalidSourceFormat(String)
    case converterUnavailable(from: String, to: String)
    case bufferAllocationFailed
    case conversionFailed(String)
    case noMicrophoneAvailable
    case tapCreationFailed(OSStatus)
    case aggregateDeviceFailed(OSStatus)
    case ioProcFailed(OSStatus)
    case notRecording

    public var errorDescription: String? {
        switch self {
        case .invalidSourceFormat(let format):
            "Audio source has an unusable format (\(format)). Is the device connected?"
        case .converterUnavailable(let from, let to):
            "Cannot convert audio from \(from) to \(to)."
        case .bufferAllocationFailed:
            "Could not allocate an audio buffer."
        case .conversionFailed(let reason):
            "Audio conversion failed: \(reason)"
        case .noMicrophoneAvailable:
            "No microphone is available."
        case .tapCreationFailed(let status):
            "Could not tap system audio (\(CoreAudioError.fourCharCode(status))). "
                + "Grant System Audio Recording in System Settings > Privacy & Security."
        case .aggregateDeviceFailed(let status):
            "Could not create the capture device (\(CoreAudioError.fourCharCode(status)))."
        case .ioProcFailed(let status):
            "Could not start audio capture (\(CoreAudioError.fourCharCode(status)))."
        case .notRecording:
            "Not currently recording."
        }
    }
}
