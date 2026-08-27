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
    private var loading: Task<AsrManager, any Error>?

    public init(version: ParakeetVersion = .v3) {
        self.version = version
    }

    /// Loads the weights once, even if several callers ask at the same time.
    ///
    /// `guard manager == nil` is not enough on its own. Actors are reentrant, so
    /// the actor is released for the whole duration of the load below and
    /// `manager` stays nil throughout — a second caller arriving in that window
    /// sails past the check and starts a *second* load of the same weights. The
    /// app does exactly that: it preloads the dictation model at launch while
    /// the hotkey is already live, so pressing it a few seconds in kicks off a
    /// concurrent load of the same 483 MB model. Holding the in-flight task
    /// rather than only the finished result is what makes this idempotent.
    public func prepare(progress: ProgressHandler?) async throws {
        if manager != nil { return }
        if let loading {
            manager = try await loading.value
            return
        }

        let name = version.displayName
        progress?(.downloadingModel(name: name, fraction: nil))

        // `AsrModels` carries its own version, and `AsrManager` reads the
        // vocabulary size and decoder shape from it, so the manager needs no
        // separate configuration per version.
        // `Task` rather than `Task.detached` so the load inherits this actor's
        // executor and priority instead of running at an unrelated one. Actor
        // reentrancy is what lets us await it from inside the actor without
        // deadlocking, and is the same property that makes the guard above
        // insufficient on its own.
        let asrVersion = version.asrVersion
        let task = Task {
            let models = try await AsrModels.downloadAndLoad(version: asrVersion)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        loading = task

        do {
            progress?(.loadingModel(name: name))
            let loaded = try await task.value
            manager = loaded
            loading = nil
        } catch {
            // Cleared so a later attempt can retry rather than inheriting the
            // failure forever.
            loading = nil
            throw TranscriptionError.modelUnavailable(name)
        }
    }

    /// `wordTimings` is ignored: Parakeet returns per-token timings from every
    /// decode whether or not anyone wants them, so there is nothing to switch
    /// off and no cost to always supplying the words.
    public func transcribe(
        url: URL,
        wordTimings: Bool,
        progress: ProgressHandler?
    ) async throws -> [RawSegment] {
        try await prepare(progress: progress)
        guard let manager else { throw TranscriptionError.modelUnavailable("parakeet") }

        guard AudioLoader.duration(of: url) > 0 else {
            throw TranscriptionError.audioFileEmpty(url)
        }

        progress?(.transcribing(fraction: nil))
        do {
            // The layer count has to come from the loaded model. `TdtDecoderState()`
            // defaults to 2, which is right for Parakeet v2 and v3 and wrong for
            // TDT-CTC 110M, which has 1 — and the decoder's CoreML input shape is
            // fixed, so the mismatch throws rather than degrading:
            //
            //   MultiArray shape (2 x 1 x 640) does not match the shape (1 x 1 x 640)
            //
            // Only clips at or under 15s were affected, because longer audio goes
            // through FluidAudio's chunker, which builds its own correctly-sized
            // state. That is the whole of dictation, which is why 110M looked
            // completely broken there while meetings mostly worked.
            var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
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
                // Older FluidAudio passed the SentencePiece marker through raw;
                // 0.15 hands back a plain leading space instead. Both mean the
                // same thing — see ``startsWord(_:)``.
                .replacingOccurrences(of: "\u{2581}", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.containsSpeech {
                segments.append(RawSegment(
                    start: first.startTime,
                    end: last.endTime,
                    text: text,
                    words: words(from: currentTokens)
                ))
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

    /// Does this token begin a new word?
    ///
    /// FluidAudio has used two conventions. Up to 0.14 the raw SentencePiece
    /// marker `▁` came through; 0.15 replaces it with a plain leading space, so
    /// `" H"`, `"ow"`, `" do"`, `"es"` is what a Parakeet decode looks like now.
    /// Accepting both is a two-character guard against a silent regression:
    /// keying on `▁` alone made every segment come back as one enormous word,
    /// which is not a crash and not a wrong transcript — it just quietly turned
    /// word-level speaker attribution back into segment-level.
    static func startsWord(_ token: String) -> Bool {
        token.hasPrefix(" ") || token.hasPrefix("\u{2581}")
    }

    /// Reassemble sub-word tokens into words.
    ///
    /// Parakeet decodes pieces, so "microphone" arrives as five tokens and a
    /// question mark arrives as its own. A new word starts at a boundary marker,
    /// and everything after it — including trailing punctuation — belongs to the
    /// word it was attached to, which is what makes a word's span the span of
    /// the audio it was actually spoken in.
    static func words(from timings: [TokenTiming]) -> [TimedWord]? {
        var words: [TimedWord] = []
        var text = ""
        var start: TimeInterval = 0
        var end: TimeInterval = 0

        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Punctuation on its own is not a word, but it did happen inside
            // the previous one's neighbourhood, so extend that instead of
            // emitting a wordless span the assembler would have to label.
            if trimmed.containsSpeech {
                words.append(TimedWord(start: start, end: max(end, start), text: trimmed))
            } else if !trimmed.isEmpty, var last = words.popLast() {
                last.text += trimmed
                last.end = max(last.end, end)
                words.append(last)
            }
            text = ""
        }

        for timing in timings {
            if startsWord(timing.token) {
                flush()
                start = timing.startTime
            } else if text.isEmpty {
                start = timing.startTime
            }
            text += timing.token.drop { $0 == " " || $0 == "\u{2581}" }
            end = timing.endTime
        }
        flush()

        return words.isEmpty ? nil : words
    }
}

/// pyannote community-1 diarization, from FluidAudio.
///
/// This is the *offline* pipeline — segmentation, WeSpeaker embeddings and VBx
/// clustering — rather than the streaming `DiarizerManager` this used to call.
/// The difference is not marginal. On FluidAudio's own AMI single-distant-mic
/// benchmark, the arrangement closest to what a call actually sounds like, the
/// streaming pipeline scores 17.7% DER and this one 10.6%, and it gets the
/// speaker count right on 12 of 16 meetings. Guessing how many people are in
/// the room is most of what a diarizer is for, and it is exactly what fell over
/// on longer calls: the more people talk, the more ways there are to merge two
/// of them into one.
///
/// It costs a slower pass — around 70x realtime rather than 130x — which is a
/// quarter of a minute on an hour of audio, and nothing next to transcribing it.
///
/// Its `TimedSpeakerSegment` carries a speaker embedding, which is the hook for
/// cross-meeting speaker memory later.
public actor FluidAudioDiarizer: DiarizationEngine {
    public nonisolated let kind = EngineKind.fluidAudio

    static let displayName = "pyannote community-1 (FluidAudio)"

    private var manager: OfflineDiarizerManager?

    public init() {}

    public func prepare(progress: ProgressHandler?) async throws {
        guard manager == nil else { return }

        progress?(.downloadingModel(name: Self.displayName, fraction: nil))
        do {
            // Loading the models by hand rather than through the manager's own
            // `prepareModels()`, which swallows the error and leaves the manager
            // silently uninitialised — the failure would then surface much later
            // as "model not loaded" from the middle of a meeting.
            let models = try await OfflineDiarizerModels.load(
                progressHandler: { progress?(.downloadingModel(
                    name: Self.displayName,
                    fraction: $0.fractionCompleted
                )) }
            )
            progress?(.loadingModel(name: Self.displayName))
            let manager = OfflineDiarizerManager()
            manager.initialize(models: models)
            self.manager = manager
        } catch {
            throw TranscriptionError.modelUnavailable(Self.displayName)
        }
    }

    public func diarize(url: URL, progress: ProgressHandler?) async throws -> [SpeakerTurn] {
        try await prepare(progress: progress)
        guard let manager else { throw TranscriptionError.modelUnavailable("pyannote") }

        guard AudioLoader.duration(of: url) > 0 else {
            throw TranscriptionError.audioFileEmpty(url)
        }

        progress?(.diarizing(fraction: nil))
        do {
            // The URL overload streams the file from disk instead of holding
            // every sample in memory, which matters on a long meeting.
            let result = try await manager.process(url) { done, total in
                guard total > 0 else { return }
                progress?(.diarizing(fraction: Double(done) / Double(total)))
            }
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
