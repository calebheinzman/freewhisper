import AVFoundation
import Foundation
import Testing

@testable import FreeWhisperKit

@Suite("WAV chunking")
struct WAVChunkerTests {
    /// 16 kHz 16-bit mono: 32 kB of file per second of audio.
    static let bytesPerSecond = 32_000

    @Test("a file under the limit is passed through, not copied")
    func smallFilePassesThrough() throws {
        let url = try write(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let chunks = try WAVChunker.chunks(of: url, maxBytes: 1_024 * 1_024)
        #expect(chunks.count == 1)
        #expect(chunks[0].url == url)
        #expect(chunks[0].offset == 0)
        #expect(!chunks[0].isTemporary)
    }

    @Test("an oversized file is split into pieces under the limit")
    func largeFileSplits() throws {
        let url = try write(seconds: 10)
        defer { try? FileManager.default.removeItem(at: url) }

        // Roughly 3 seconds per chunk.
        let maxBytes = Self.bytesPerSecond * 3
        let chunks = try WAVChunker.chunks(of: url, maxBytes: maxBytes)
        defer { WAVChunker.cleanUp(chunks) }

        #expect(chunks.count >= 4)
        for chunk in chunks {
            let size = try chunk.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            #expect(size <= maxBytes, "chunk \(chunk.url.lastPathComponent) is over the limit")
            #expect(chunk.isTemporary)
        }
    }

    /// Offsets are the whole point: they are what turns per-chunk timestamps
    /// back into timestamps for the meeting. Off-by-one here silently shifts
    /// every line after the first seam.
    @Test("offsets are continuous and cover the original duration")
    func offsetsAreContinuous() throws {
        let url = try write(seconds: 10)
        defer { try? FileManager.default.removeItem(at: url) }

        let chunks = try WAVChunker.chunks(of: url, maxBytes: Self.bytesPerSecond * 3)
        defer { WAVChunker.cleanUp(chunks) }

        #expect(chunks[0].offset == 0)

        var expected: TimeInterval = 0
        for chunk in chunks {
            #expect(abs(chunk.offset - expected) < 0.001, "gap or overlap at \(chunk.offset)s")
            expected += AudioLoader.duration(of: chunk.url)
        }
        #expect(abs(expected - 10) < 0.05, "chunks total \(expected)s, not 10s")
    }

    @Test("temporary chunks are cleaned up")
    func cleanUpRemovesChunks() throws {
        let url = try write(seconds: 10)
        defer { try? FileManager.default.removeItem(at: url) }

        let chunks = try WAVChunker.chunks(of: url, maxBytes: Self.bytesPerSecond * 3)
        WAVChunker.cleanUp(chunks)

        for chunk in chunks {
            #expect(!FileManager.default.fileExists(atPath: chunk.url.path))
        }
        #expect(FileManager.default.fileExists(atPath: url.path), "cleanUp deleted the original")
    }

    /// The seam exists so a cut lands in a pause rather than mid-word. Given
    /// tone-silence-tone, it should choose the silence.
    @Test("the seam lands on the quiet stretch, not the target sample")
    func seamPrefersSilence() {
        let rate = Int(AudioFormats.sampleRate)
        var samples = [Float](repeating: 0.5, count: rate * 10)
        // A second of silence ending 1s before the target.
        let quietStart = rate * 6
        for index in quietStart..<(quietStart + rate) {
            samples[index] = 0
        }

        let target = rate * 8
        let seam = WAVChunker.seam(in: samples, from: 0, target: target)
        #expect(seam >= quietStart && seam < quietStart + rate,
                "seam at \(seam) is outside the silence at \(quietStart)..<\(quietStart + rate)")
    }

    @Test("the seam never runs past the target, which is the size limit")
    func seamNeverExceedsTarget() {
        let rate = Int(AudioFormats.sampleRate)
        // Loudest right where the seam wants to go: it must still not overrun.
        let samples = [Float](repeating: 0.5, count: rate * 10)
        let target = rate * 8
        #expect(WAVChunker.seam(in: samples, from: 0, target: target) <= target)
    }

    // MARK: Helpers

    /// A 440 Hz tone, so chunks contain real signal rather than silence the
    /// duration maths could accidentally get right.
    private func write(seconds: Double) throws -> URL {
        let rate = AudioFormats.sampleRate
        let count = Int(seconds * rate)
        let samples = (0..<count).map { index in
            Float(sin(2 * Double.pi * 440 * Double(index) / rate)) * 0.5
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunker-\(UUID().uuidString).wav")
        let file = try AVAudioFile(
            forWriting: url,
            settings: AudioFormats.fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let buffer = AVAudioPCMBuffer(
            pcmFormat: AudioFormats.processing,
            frameCapacity: AVAudioFrameCount(count)
        )!
        samples.withUnsafeBufferPointer {
            buffer.floatChannelData![0].update(from: $0.baseAddress!, count: count)
        }
        buffer.frameLength = AVAudioFrameCount(count)
        try file.write(from: buffer)
        return url
    }
}
