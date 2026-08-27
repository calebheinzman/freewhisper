import AVFoundation
import Foundation

/// Splits a recording into pieces small enough to upload.
///
/// Cloud transcription endpoints cap the request body at roughly 25 MB. Our
/// recordings are 16 kHz 16-bit mono WAV — 32 kB per second — so an hour-long
/// meeting is ~115 MB and has to go up in pieces.
///
/// Transcoding to a compressed format would avoid the split entirely, but it
/// would also hand the endpoint audio that is no longer the audio we recorded,
/// and lossy encoding is exactly the wrong thing to do to speech you are about
/// to run through ASR. Splitting keeps the samples intact.
enum WAVChunker {
    struct Chunk: Sendable {
        let url: URL
        /// Seconds from the start of the original recording, to add back onto
        /// whatever timestamps come out of the transcriber.
        let offset: TimeInterval
        /// False for the pass-through case, so the caller knows not to delete
        /// the user's actual recording.
        let isTemporary: Bool
    }

    /// 24 MB against a 25 MB limit: the multipart envelope and the WAV header
    /// both add to the body, and being a megabyte under is cheaper than a
    /// rejected upload of a whole meeting.
    static let defaultMaxBytes = 24 * 1_024 * 1_024

    /// How far back from a target boundary to look for a quiet moment.
    static let seamSearchSeconds: Double = 3
    /// Granularity of that search. Short enough to land inside a pause between
    /// words, long enough that a single click doesn't win.
    static let seamFrameSeconds: Double = 0.1
    /// What counts as a pause. Same threshold the Whisper engine uses to decide
    /// a segment sits over silence, for the same reason: it is well below
    /// conversational speech, so a soft talker still reads as speaking.
    static let seamSilenceThreshold: Float = 0.004

    /// Splits `url` if it exceeds `maxBytes`, otherwise hands it back untouched.
    ///
    /// Temporary chunks are written to their own directory; the caller is
    /// responsible for removing it via ``cleanUp(_:)``.
    static func chunks(
        of url: URL,
        maxBytes: Int = defaultMaxBytes
    ) throws -> [Chunk] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptionError.audioFileMissing(url)
        }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > maxBytes else {
            return [Chunk(url: url, offset: 0, isTemporary: false)]
        }

        let samples = try AudioLoader.loadSamples(from: url)
        guard !samples.isEmpty else { throw TranscriptionError.audioFileEmpty(url) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fw-upload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let rate = AudioFormats.sampleRate
        // Two bytes per sample on disk. The reserve covers the WAV header,
        // which AVAudioFile writes with rather more padding than the canonical
        // 44 bytes — measured at ~4 kB — and the multipart envelope around it.
        let maxSamples = max(1, (maxBytes - 8_192) / 2)

        var chunks: [Chunk] = []
        var cursor = 0
        while cursor < samples.count {
            let remaining = samples.count - cursor
            let end = remaining <= maxSamples
                ? samples.count
                : seam(in: samples, from: cursor, target: cursor + maxSamples)

            let file = directory.appendingPathComponent(
                String(format: "chunk-%03d.wav", chunks.count)
            )
            try AudioLoader.write(Array(samples[cursor..<end]), to: file)
            chunks.append(
                Chunk(url: file, offset: Double(cursor) / rate, isTemporary: true)
            )
            cursor = end
        }

        Log.transcription.info("split \(url.lastPathComponent, privacy: .public) into \(chunks.count) chunks")
        return chunks
    }

    static func cleanUp(_ chunks: [Chunk]) {
        for directory in Set(chunks.filter(\.isTemporary).map { $0.url.deletingLastPathComponent() }) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Finds the last pause before `target`, or `target` if there isn't one.
    ///
    /// The search never goes past `target`, because that is the size limit — a
    /// seam may make a chunk shorter, never longer. Cutting on a pause rather
    /// than an arbitrary sample keeps a word from being severed and
    /// transcribed as two half-words.
    ///
    /// Scanning backwards for the *nearest* silence, rather than for the
    /// quietest frame in the window, matters more than it looks: over audio
    /// with no pause at all — steady noise, music, a continuous talker — the
    /// quietest-frame rule has to pick something, and picking a frame near the
    /// start of the window would carve a full-size chunk down to a sliver and
    /// turn one upload into dozens.
    static func seam(in samples: [Float], from start: Int, target: Int) -> Int {
        let rate = AudioFormats.sampleRate
        let frame = max(1, Int(seamFrameSeconds * rate))
        let target = min(target, samples.count)
        let earliest = max(start + frame, target - Int(seamSearchSeconds * rate))
        guard earliest + frame <= target else { return target }

        var candidate = target - frame
        while candidate >= earliest {
            if rms(samples, from: candidate, to: candidate + frame) < seamSilenceThreshold {
                // Cut in the middle of the quiet frame rather than at its edge,
                // which puts the maximum distance between the seam and whatever
                // speech sits on either side of it.
                return candidate + frame / 2
            }
            candidate -= frame
        }
        return target
    }

    private static func rms(_ samples: [Float], from start: Int, to end: Int) -> Float {
        var sumOfSquares: Float = 0
        for index in start..<end {
            sumOfSquares += samples[index] * samples[index]
        }
        return (sumOfSquares / Float(end - start)).squareRoot()
    }
}
