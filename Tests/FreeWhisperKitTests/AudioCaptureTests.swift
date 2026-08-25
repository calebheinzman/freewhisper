import AVFoundation
import Foundation
import Testing

@testable import FreeWhisperKit

@Suite("Level metering")
struct MeterScaleTests {
    @Test("silence reads as zero")
    func silence() {
        #expect(ResamplingRecorder.meterScale(0) == 0)
    }

    @Test("full scale reads as one")
    func fullScale() {
        #expect(ResamplingRecorder.meterScale(1.0) == 1.0)
    }

    @Test("the -60 dB floor clamps to zero rather than going negative")
    func belowFloor() {
        // -80 dBFS is well under the floor and must not produce a negative bar.
        #expect(ResamplingRecorder.meterScale(0.0001) == 0)
    }

    @Test("quiet speech lands in a visible part of the bar")
    func speechIsVisible() {
        // A linear meter renders speech-level RMS as essentially nothing, which
        // is the bug this scale exists to fix.
        let quietSpeech = ResamplingRecorder.meterScale(0.01) // -40 dBFS
        #expect(quietSpeech > 0.25)
        #expect(quietSpeech < 0.5)
    }

    @Test("the scale is monotonic")
    func monotonic() {
        let levels: [Float] = [0.001, 0.01, 0.05, 0.2, 0.5, 1.0]
        let scaled = levels.map { ResamplingRecorder.meterScale($0) }
        #expect(zip(scaled, scaled.dropFirst()).allSatisfy { $0 <= $1 })
    }
}

@Suite("Resampling to the ASR format")
struct ResamplingRecorderTests {
    /// The engines all want 16 kHz mono, and both capture paths deliver
    /// something else — the mic is typically 48 kHz mono and the system tap is
    /// 44.1 or 48 kHz stereo. Prove the conversion actually happens.
    @Test("48 kHz stereo input becomes a 16 kHz mono file of the same duration")
    func downsamplesAndDownmixes() throws {
        let source = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        )!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("resample-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = try ResamplingRecorder(url: url, sourceFormat: source)

        // Two seconds of a 440 Hz tone.
        let frames = AVAudioFrameCount(48_000)
        for _ in 0..<2 {
            let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames)!
            buffer.frameLength = frames
            for channel in 0..<2 {
                let samples = buffer.floatChannelData![channel]
                for frame in 0..<Int(frames) {
                    samples[frame] = 0.5 * sin(2 * .pi * 440 * Float(frame) / 48_000)
                }
            }
            try recorder.write(buffer)
        }
        recorder.close()

        let written = try AVAudioFile(forReading: url)
        #expect(written.fileFormat.sampleRate == 16_000)
        #expect(written.fileFormat.channelCount == 1)

        // Resampler edge effects cost a few frames; a tenth of a second of
        // tolerance on two seconds is plenty tight to catch a rate mistake.
        let duration = Double(written.length) / written.fileFormat.sampleRate
        #expect(abs(duration - 2.0) < 0.1)
    }

    @Test("a tone registers a peak well above the silence threshold")
    func peakTracksSignal() throws {
        let source = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("peak-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = try ResamplingRecorder(url: url, sourceFormat: source)
        let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        for frame in 0..<16_000 {
            buffer.floatChannelData![0][frame] = 0.5 * sin(2 * .pi * 440 * Float(frame) / 16_000)
        }
        try recorder.write(buffer)

        #expect(recorder.peak > ResamplingRecorder.silenceThreshold)
        #expect(recorder.peak <= 1.0)
        recorder.close()
    }

    @Test("digital silence stays under the silence threshold")
    func silenceIsDetected() throws {
        let source = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quiet-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = try ResamplingRecorder(url: url, sourceFormat: source)
        let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 16_000)!
        buffer.frameLength = 16_000 // zero-filled
        try recorder.write(buffer)

        #expect(recorder.peak < ResamplingRecorder.silenceThreshold)
        recorder.close()
    }
}
