import Foundation
import FluidAudio

/// Bridges our own version enum onto FluidAudio's.
///
/// Kept here rather than in ``ModelCatalog`` because this is the file that owns
/// the FluidAudio import; the catalog only needs the mapping for cache paths.
extension ParakeetVersion {
    var asrVersion: AsrModelVersion {
        switch self {
        case .v3: .v3
        case .v2: .v2
        case .tdtCtc110m: .tdtCtc110m
        }
    }

    var displayName: String {
        switch self {
        case .v3: "parakeet-tdt-0.6b-v3"
        case .v2: "parakeet-tdt-0.6b-v2"
        case .tdtCtc110m: "parakeet-tdt-ctc-110m"
        }
    }
}

/// Parakeet TDT ASR, from FluidAudio.
///
/// Measured at roughly 8x faster than WhisperKit on the same clip on an M1 Max,
/// at the cost of covering 25 European languages rather than Whisper's 90+.
///
/// Note: FluidAudio mirrors its internal logging to stdout under `#if DEBUG`,
/// with no public switch to turn it off. Release builds are quiet.
public actor FluidAudioEngine: TranscriptionEngine {
    public nonisolated let kind = EngineKind.fluidAudio

    private let version: ParakeetVersion
    private var manager: AsrManager?

    public init(version: ParakeetVersion = .v3) {
        self.version = version
    }

    public func prepare(progress: ProgressHandler?) async throws {
        guard manager == nil else { return }

        let name = version.displayName
        progress?(.downloadingModel(name: name, fraction: nil))
        do {
            // `AsrModels` carries its own version, and `AsrManager` reads the
            // vocabulary size and decoder shape from it, so the manager needs
            // no separate configuration per version.
            let models = try await AsrModels.downloadAndLoad(version: version.asrVersion)
            progress?(.loadingModel(name: name))
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            self.manager = manager
        } catch {
            throw TranscriptionError.modelUnavailable(name)
        }
    }

    public func transcribe(url: URL, progress: ProgressHandler?) async throws -> [RawSegment] {
        try await prepare(progress: progress)
        guard let manager else { throw TranscriptionError.modelUnavailable("parakeet") }

        guard AudioLoader.duration(of: url) > 0 else {
            throw TranscriptionError.audioFileEmpty(url)
        }

        progress?(.transcribing(fraction: nil))
        do {
            var decoderState = try TdtDecoderState()
            let result = try await manager.transcribe(url, decoderState: &decoderState)
            return Self.segments(from: result)
        } catch {
            throw TranscriptionError.engineFailed(
                engine: "FluidAudio",
                reason: error.localizedDescription
            )
        }
    }

    /// Parakeet returns one flat string plus per-token timings, where Whisper
    /// returns ready-made segments. Rebuild sentence-ish segments by splitting
    /// on pauses and terminal punctuation so both engines produce a comparable
    /// shape for the assembler.
    static func segments(from result: ASRResult) -> [RawSegment] {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.containsSpeech else { return [] }

        guard let timings = result.tokenTimings, !timings.isEmpty else {
            // No timings: emit one segment spanning the whole file rather than
            // losing the transcript entirely.
            return [RawSegment(start: 0, end: result.duration, text: text)]
        }

        return groupIntoSegments(timings)
    }

    /// A pause longer than this starts a new segment.
    static let pauseThreshold: TimeInterval = 0.6
    /// Cap on segment length, so a monologue without punctuation still breaks up.
    static let maxSegmentDuration: TimeInterval = 20

    static func groupIntoSegments(_ timings: [TokenTiming]) -> [RawSegment] {
        var segments: [RawSegment] = []
        var currentTokens: [TokenTiming] = []

        func flush() {
            guard let first = currentTokens.first, let last = currentTokens.last else { return }
            let text = currentTokens
                .map(\.token)
                .joined()
                // Parakeet uses the SentencePiece word-boundary marker.
                .replacingOccurrences(of: "\u{2581}", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.containsSpeech {
                segments.append(RawSegment(start: first.startTime, end: last.endTime, text: text))
            }
            currentTokens = []
        }

        for timing in timings {
            if let previous = currentTokens.last {
                let gap = timing.startTime - previous.endTime
                let elapsed = timing.endTime - (currentTokens.first?.startTime ?? timing.startTime)
                let endsSentence = previous.token.hasSuffix(".")
                    || previous.token.hasSuffix("?")
                    || previous.token.hasSuffix("!")

                if gap > pauseThreshold || elapsed > maxSegmentDuration || endsSentence {
                    flush()
                }
            }
            currentTokens.append(timing)
        }
        flush()

        return segments
    }
}

/// pyannote diarization, from FluidAudio.
///
/// Its `TimedSpeakerSegment` carries a speaker embedding, which is the hook for
/// cross-meeting speaker memory later.
public actor FluidAudioDiarizer: DiarizationEngine {
    public nonisolated let kind = EngineKind.fluidAudio

    private var manager: DiarizerManager?

    public init() {}

    public func prepare(progress: ProgressHandler?) async throws {
        guard manager == nil else { return }

        progress?(.downloadingModel(name: "pyannote (FluidAudio)", fraction: nil))
        do {
            let models = try await DiarizerModels.downloadIfNeeded()
            progress?(.loadingModel(name: "pyannote (FluidAudio)"))
            let manager = DiarizerManager()
            manager.initialize(models: consume models)
            self.manager = manager
        } catch {
            throw TranscriptionError.modelUnavailable("pyannote (FluidAudio)")
        }
    }

    public func diarize(url: URL, progress: ProgressHandler?) async throws -> [SpeakerTurn] {
        try await prepare(progress: progress)
        guard let manager else { throw TranscriptionError.modelUnavailable("pyannote") }

        let samples = try AudioLoader.loadSamples(from: url)
        guard !samples.isEmpty else { throw TranscriptionError.audioFileEmpty(url) }

        progress?(.diarizing(fraction: nil))
        do {
            let result = try manager.performCompleteDiarization(samples)
            return result.segments.map {
                SpeakerTurn(
                    start: TimeInterval($0.startTimeSeconds),
                    end: TimeInterval($0.endTimeSeconds),
                    speakerID: "speaker_\($0.speakerId)"
                )
            }
        } catch {
            throw TranscriptionError.engineFailed(
                engine: "FluidAudio diarizer",
                reason: error.localizedDescription
            )
        }
    }
}
