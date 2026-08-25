import Foundation
import SpeakerKit
import WhisperKit

/// Whisper via CoreML, from argmax-oss-swift.
///
/// Models come from the public `argmaxinc/whisperkit-coreml` HuggingFace repo
/// and need no token. The first `prepare()` downloads several hundred MB.
public actor WhisperKitEngine: TranscriptionEngine {
    public nonisolated let kind = EngineKind.whisperKit

    /// Above this, Whisper itself believes the window contained no speech.
    static let noSpeechThreshold: Float = 0.6

    /// Whisper's native context window. Audio shorter than this needs no
    /// chunking at all.
    static let whisperWindowSeconds: Double = 30

    /// The exact folder name in `argmaxinc/whisperkit-coreml`, which is also
    /// what `WhisperKitConfig` matches on.
    private let modelName: String
    private var pipe: WhisperKit?
    private var loading: Task<WhisperKit, any Error>?

    /// No default: an engine that doesn't know which weights it runs is not a
    /// thing worth being able to construct, now that there is more than one set.
    public init(variant: String) {
        self.modelName = variant
    }

    /// Loads the weights once, even if several callers ask at the same time.
    /// See ``FluidAudioEngine/prepare(progress:)`` for why the obvious
    /// `guard pipe == nil` is not sufficient on a reentrant actor.
    public func prepare(progress: ProgressHandler?) async throws {
        if pipe != nil { return }
        if let loading {
            pipe = try await loading.value
            return
        }

        progress?(.downloadingModel(name: modelName, fraction: nil))

        let model = modelName
        let base = ModelStorage.downloadBase()
        let task = Task.detached {
            try await WhisperKit(WhisperKitConfig(model: model, downloadBase: base, download: true))
        }
        loading = task

        do {
            progress?(.loadingModel(name: modelName))
            let loaded = try await task.value
            pipe = loaded
            loading = nil
        } catch {
            loading = nil
            throw TranscriptionError.modelUnavailable(modelName)
        }
    }

    public func transcribe(url: URL, progress: ProgressHandler?) async throws -> [RawSegment] {
        try await prepare(progress: progress)
        guard let pipe else { throw TranscriptionError.modelUnavailable(modelName) }

        let samples = try AudioLoader.loadSamples(from: url)
        guard !samples.isEmpty else { throw TranscriptionError.audioFileEmpty(url) }

        progress?(.transcribing(fraction: nil))
        do {
            // VAD chunking exists to handle recordings longer than Whisper's
            // 30s context window. Below that it is pointless work — measured at
            // 4.4s versus 5.2s on a 7s clip — and dictation clips are short.
            let duration = Double(samples.count) / AudioFormats.sampleRate
            let options = DecodingOptions(
                task: .transcribe,
                skipSpecialTokens: true,
                chunkingStrategy: duration > Self.whisperWindowSeconds ? .vad : .none
            )
            let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)

            return results
                .flatMap(\.segments)
                .filter { $0.noSpeechProb < Self.noSpeechThreshold }
                .map {
                    RawSegment(
                        start: TimeInterval($0.start),
                        end: TimeInterval($0.end),
                        text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
                .filter { $0.text.containsSpeech }
                .filter { Self.hasAudibleSpeech($0, in: samples) }
                .filter { !Self.isKnownArtifact($0) }
        } catch {
            throw TranscriptionError.engineFailed(
                engine: "WhisperKit",
                reason: error.localizedDescription
            )
        }
    }

    /// Whisper invents text over silence, and "Thank you." over a quiet
    /// microphone is close to a signature of it. Rather than blocklisting
    /// phrases — which would eventually delete something a person really said —
    /// check the audio the segment claims to describe. If there is no energy
    /// there, there were no words there.
    ///
    /// The threshold is well below conversational speech, so a soft talker or a
    /// distant microphone still passes; only genuine near-silence is cut.
    static let segmentSilenceThreshold: Float = 0.004

    /// The handful of things Whisper emits over trailing silence, where the
    /// energy check does not help because the window abuts real speech.
    ///
    /// A blocklist is a blunt instrument and this one is deliberately tiny: it
    /// only fires on a lone token, so "you" as a whole utterance is lost but
    /// "you were right" is untouched. Someone saying nothing but "You." is rare
    /// enough, and one dropped word beats a transcript peppered with phantom
    /// lines that make the whole thing look unreliable.
    static let knownArtifacts: Set<String> = ["you", "thank you", "thanks", "bye", "the"]

    static func isKnownArtifact(_ segment: RawSegment) -> Bool {
        let normalized = segment.text
            .lowercased()
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard knownArtifacts.contains(normalized) else { return false }

        Log.transcription.debug("dropped artifact: \(segment.text, privacy: .public)")
        return true
    }

    static func hasAudibleSpeech(_ segment: RawSegment, in samples: [Float]) -> Bool {
        let rate = AudioFormats.sampleRate
        let start = max(0, Int(segment.start * rate))
        let end = min(samples.count, Int(segment.end * rate))
        guard start < end else { return true }

        var sumOfSquares: Float = 0
        for index in start..<end {
            sumOfSquares += samples[index] * samples[index]
        }
        let rms = (sumOfSquares / Float(end - start)).squareRoot()

        if rms < segmentSilenceThreshold {
            Log.transcription.debug("dropped hallucination over silence: \(segment.text, privacy: .public)")
            return false
        }
        return true
    }
}

/// pyannote diarization, from argmax-oss-swift's SpeakerKit.
public actor SpeakerKitDiarizer: DiarizationEngine {
    public nonisolated let kind = EngineKind.whisperKit

    /// How readily embeddings are merged into one speaker. Lower splits more,
    /// higher merges more. Nil uses pyannote's own default.
    ///
    /// Left unset deliberately: clustering quality varies enormously with mic
    /// setup and voice similarity, and a value tuned on one recording is as
    /// likely to hurt as help. Exposed as a setting instead, alongside the
    /// ability to merge two speakers by giving them the same name.
    private let clusterDistanceThreshold: Float?
    private var speakerKit: SpeakerKit?

    public init(clusterDistanceThreshold: Float? = nil) {
        self.clusterDistanceThreshold = clusterDistanceThreshold
    }

    public func prepare(progress: ProgressHandler?) async throws {
        guard speakerKit == nil else { return }

        progress?(.downloadingModel(name: "pyannote", fraction: nil))
        do {
            speakerKit = try await SpeakerKit(PyannoteConfig(
                downloadBase: ModelStorage.downloadBase().path
            ))
        } catch {
            throw TranscriptionError.modelUnavailable("pyannote (SpeakerKit)")
        }
    }

    public func diarize(url: URL, progress: ProgressHandler?) async throws -> [SpeakerTurn] {
        try await prepare(progress: progress)
        guard let speakerKit else { throw TranscriptionError.modelUnavailable("pyannote") }

        let samples = try AudioLoader.loadSamples(from: url)
        guard !samples.isEmpty else { throw TranscriptionError.audioFileEmpty(url) }

        progress?(.diarizing(fraction: nil))
        do {
            let options = clusterDistanceThreshold.map {
                PyannoteDiarizationOptions(clusterDistanceThreshold: $0)
            }
            let result = try await speakerKit.diarize(audioArray: samples, options: options)
            return result.segments.compactMap { segment in
                // Drop `.noMatch` and overlapping-speech `.multiple` spans: with
                // nobody to attribute the words to, a turn here would only cause
                // the assembler to mislabel them.
                guard let id = segment.speaker.speakerId else { return nil }
                return SpeakerTurn(
                    start: TimeInterval(segment.startTime),
                    end: TimeInterval(segment.endTime),
                    speakerID: "speaker_\(id)"
                )
            }
        } catch {
            throw TranscriptionError.engineFailed(
                engine: "SpeakerKit",
                reason: error.localizedDescription
            )
        }
    }
}
