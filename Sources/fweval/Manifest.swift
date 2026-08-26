import AVFoundation
import Foundation
import FreeWhisperKit

/// One benchmark corpus, prepared by `eval/prepare/`.
///
/// The Swift side deliberately knows nothing about datasets, licences or
/// metrics: Python normalizes nine very different corpora into this one shape,
/// and everything here just runs models over whatever it is handed. Adding a
/// tenth dataset should never mean recompiling.
struct Manifest: Decodable {
    var dataset: String
    var track: String
    var items: [Item]

    struct Item: Decodable {
        var id: String
        /// Audio to run, for the `asr` and `meeting` tracks.
        var audio: String?
        /// A gold ``Transcript`` on disk, for the `summarize` track. Feeding
        /// text rather than audio is the point: it scores the summarizer
        /// without ASR error bleeding into the number.
        var transcript: String?
    }

    static func load(_ url: URL) throws -> Manifest {
        var manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        // Paths are stored relative to the manifest so the checked-in files stay
        // machine-independent, while `eval/datasets/` is gitignored.
        let base = url.deletingLastPathComponent()
        manifest.items = manifest.items.map { item in
            var item = item
            item.audio = item.audio.map { Self.resolve($0, against: base) }
            item.transcript = item.transcript.map { Self.resolve($0, against: base) }
            return item
        }
        return manifest
    }

    private static func resolve(_ path: String, against base: URL) -> String {
        path.hasPrefix("/") ? path : base.appendingPathComponent(path).standardizedFileURL.path
    }
}

/// What one model produced for one item, plus what it cost.
///
/// A single shape across all three tracks, with the fields a given track does
/// not use left nil. One shape means one loader in the scorer.
struct ItemResult: Encodable {
    var id: String
    var model: String
    var dataset: String
    var track: String

    /// Flat text, for word-error scoring.
    var text: String?
    /// The finished transcript: ASR segments carrying the labels assembly gave
    /// them. This is what a user reads, so it is what the headline score is on.
    var segments: [Segment]?
    /// The diarizer's own turns, before any of that.
    ///
    /// Recorded separately because the two answer different questions and only
    /// one of them can be checked against the literature. Published diarization
    /// error rates score *these* — who was speaking when — whereas the segments
    /// above have already been through `TranscriptAssembler`, which attributes
    /// each ASR segment to whichever turn it overlaps most. An ASR segment that
    /// runs across a speaker change takes one label for the whole span, and that
    /// shows up as confusion that the diarizer never committed. Without both,
    /// there is no way to tell a bad diarizer from a lossy assembly step, and no
    /// way to know whether the harness itself is right.
    var speakerTurns: [Turn]?
    var summary: SummaryPayload?

    var audioSeconds: Double?
    /// Transcript size for the summary track, where there is no audio to
    /// measure a realtime factor against. Long enough inputs cross
    /// `Summarizer.mapReduceThreshold` and cost several round trips, so cost per
    /// character is the only comparable figure.
    var inputChars: Int?
    /// Wall clock for this item alone, with the model already loaded.
    var wallSeconds: Double
    /// Audio seconds per wall second. The number worth showing a user.
    var rtfx: Double?
    /// Set instead of the payload when this item failed. One bad file must not
    /// cost a three-hour run.
    var error: String?

    struct Segment: Encodable {
        var start: Double
        var end: Double
        var speaker: String
        var text: String
    }

    struct Turn: Encodable {
        var start: Double
        var end: Double
        var speaker: String
    }

    struct SummaryPayload: Encodable {
        var title: String
        var summary: String
        var keyPoints: [String]
        var actionItems: [String]
        var tags: [String]
        var speakerNames: [String: String]

        init(_ summary: MeetingSummary) {
            title = summary.title
            self.summary = summary.summary
            keyPoints = summary.keyPoints
            actionItems = summary.actionItems
            tags = summary.tags
            speakerNames = summary.speakerNames
        }
    }
}

/// Run-level facts the per-item files can't carry.
struct RunResult: Encodable {
    var model: String
    var dataset: String
    var track: String
    /// Time to get the weights loaded and ready, measured once before the loop.
    ///
    /// Kept apart from the per-item numbers rather than folded into the first
    /// item. ``EngineRegistry`` caches by model id, so in the app this is paid
    /// once and never again; blending it into a per-item average would slander
    /// every model with a large download and flatter every small one.
    var modelLoadSeconds: Double
    var totalWallSeconds: Double
    var itemCount: Int
    var failureCount: Int
    /// None of these timings transfer to another machine, so the machine is part
    /// of the result.
    var host: Host

    struct Host: Encodable {
        var chip: String
        var memoryGB: Int
        var os: String

        static func current() -> Host {
            var size = 0
            sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
            var chars = [CChar](repeating: 0, count: max(size, 1))
            sysctlbyname("machdep.cpu.brand_string", &chars, &size, nil, 0)

            let version = ProcessInfo.processInfo.operatingSystemVersion
            return Host(
                chip: String(cString: chars),
                memoryGB: Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824),
                os: "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            )
        }
    }
}

enum Output {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// One file per item, named after the item, so a run resumes by simply
    /// skipping what is already on disk.
    static func path(in directory: URL, id: String) -> URL {
        directory.appendingPathComponent("\(sanitize(id)).json")
    }

    static func write(_ value: some Encodable, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder().encode(value).write(to: url, options: .atomic)
    }

    /// Item ids come from corpora that use slashes and spaces in them.
    static func sanitize(_ id: String) -> String {
        String(id.map { "/ :".contains($0) ? "_" : $0 })
    }
}

enum Audio {
    /// Duration in seconds, for the realtime factor.
    static func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// A few seconds of quiet tone, for forcing a model to finish loading.
    ///
    /// `prepare()` is not enough on its own. WhisperKit returns from it in under
    /// two seconds and then spends four minutes compiling CoreML kernels inside
    /// the *first* `transcribe` call — which, left alone, lands entirely on the
    /// first item of the corpus and reports it as a 250-second transcription of
    /// an eight-second clip. Running one throwaway inference over this file
    /// moves that cost where it belongs, into the load figure, and leaves every
    /// measured item warm.
    ///
    /// A tone rather than digital silence: some engines short-circuit on a
    /// completely silent buffer, which would skip the very compilation this is
    /// here to force.
    static func warmupFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fweval-warmup-\(UUID().uuidString).wav")

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        )!
        let frames = AVAudioFrameCount(16_000 * 3)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames

        for frame in 0..<Int(frames) {
            buffer.floatChannelData![0][frame] = 0.05 * sinf(2 * .pi * 440 * Float(frame) / 16_000)
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
        return url
    }
}

/// A monotonic stopwatch.
///
/// `ContinuousClock` rather than `Date`: these numbers are the headline latency
/// figures, and wall-clock time can step sideways mid-run.
struct Stopwatch {
    private let started = ContinuousClock.now

    var seconds: Double {
        let elapsed = started.duration(to: ContinuousClock.now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }
}
