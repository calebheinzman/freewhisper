import AVFoundation
import Foundation

/// Loads a recorded WAV as the 16 kHz mono float array every engine expects.
enum AudioLoader {
    static func loadSamples(from url: URL) throws -> [Float] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptionError.audioFileMissing(url)
        }

        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else {
            throw TranscriptionError.audioFileEmpty(url)
        }

        // We write 16 kHz mono at capture time, so this is normally a straight
        // read. Convert anyway: a user may point the CLI at any file.
        let target = AudioFormats.processing
        if file.processingFormat.sampleRate == target.sampleRate,
           file.processingFormat.channelCount == target.channelCount {
            return try read(file, format: file.processingFormat)
        }
        return try readConverting(file, to: target)
    }

    static func duration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    // MARK: Writing

    /// Opens a new 16 kHz mono WAV for writing — the format every engine wants,
    /// and the one `ResamplingRecorder` captures into.
    ///
    /// Kept separate from ``write(_:to:)`` so a caller with more samples than it
    /// wants in memory at once can append piece by piece.
    static func makeFile(at url: URL) throws -> AVAudioFile {
        try AVAudioFile(
            forWriting: url,
            settings: AudioFormats.fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    static func append(_ samples: [Float], to file: AVAudioFile) throws {
        guard !samples.isEmpty else { return }

        let format = AudioFormats.processing
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let channel = buffer.floatChannelData?[0] else {
            throw AudioCaptureError.bufferAllocationFailed
        }

        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
    }

    static func write(_ samples: [Float], to url: URL) throws {
        let file = try makeFile(at: url)
        try append(samples, to: file)
    }

    private static func read(_ file: AVAudioFile, format: AVAudioFormat) throws -> [Float] {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw AudioCaptureError.bufferAllocationFailed
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private static func readConverting(_ file: AVAudioFile, to target: AVAudioFormat) throws -> [Float] {
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw AudioCaptureError.converterUnavailable(
                from: String(describing: file.processingFormat),
                to: String(describing: target)
            )
        }

        var samples: [Float] = []
        let chunkFrames: AVAudioFrameCount = 16_384
        let ratio = target.sampleRate / file.processingFormat.sampleRate

        while true {
            guard let input = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: chunkFrames
            ) else { break }
            try file.read(into: input, frameCount: chunkFrames)
            if input.frameLength == 0 { break }

            let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { break }

            var supplied = false
            var error: NSError?
            _ = converter.convert(to: output, error: &error) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return input
            }
            if let error {
                throw AudioCaptureError.conversionFailed(error.localizedDescription)
            }
            if let channel = output.floatChannelData?[0], output.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(
                    start: channel,
                    count: Int(output.frameLength)
                ))
            }
        }
        return samples
    }
}
