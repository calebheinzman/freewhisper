import Foundation
import Testing

@testable import FreeWhisperKit

@Suite("Cloud transcription")
struct CloudTranscriptionTests {
    // MARK: Multipart body

    @Test("the body carries the file and every field the endpoint needs")
    func bodyIsWellFormed() throws {
        let data = AudioTranscriptionClient.body(
            boundary: "BOUND",
            audio: Data("AUDIO".utf8),
            filename: "mic.wav",
            fields: ["model": "whisper-1", "response_format": "verbose_json", "temperature": "0"]
        )
        let text = try #require(String(data: data, encoding: .utf8))

        #expect(text.contains("name=\"model\"\r\n\r\nwhisper-1"))
        #expect(text.contains("name=\"response_format\"\r\n\r\nverbose_json"))
        #expect(text.contains("name=\"file\"; filename=\"mic.wav\""))
        #expect(text.contains("Content-Type: audio/wav"))
        #expect(text.contains("AUDIO"))
        #expect(text.hasSuffix("--BOUND--\r\n"), "body must end with the closing boundary")
    }

    /// An empty model name would go up as an empty field and come back as a
    /// confusing 400 rather than the "no model is set" the engine checks for.
    @Test("empty fields are left out entirely")
    func emptyFieldsAreOmitted() throws {
        let data = AudioTranscriptionClient.body(
            boundary: "B",
            audio: Data(),
            filename: "a.wav",
            fields: ["model": "", "response_format": "json"]
        )
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("name=\"model\""))
        #expect(text.contains("name=\"response_format\""))
    }

    // MARK: Response parsing

    @Test("verbose_json segments keep their timings")
    func verboseSegmentsParse() throws {
        let json = """
        {"text": "hello there general",
         "segments": [
           {"start": 0.0, "end": 1.5, "text": " hello there"},
           {"start": 1.5, "end": 2.75, "text": " general"}
         ]}
        """
        let segments = try AudioTranscriptionClient.segments(
            from: Data(json.utf8), fallbackDuration: 99
        )

        #expect(segments.count == 2)
        #expect(segments[0] == RawSegment(start: 0, end: 1.5, text: "hello there"))
        #expect(segments[1] == RawSegment(start: 1.5, end: 2.75, text: "general"))
    }

    /// Models that reject `verbose_json` give back bare text. One segment
    /// spanning the clip is all the timing information that exists.
    @Test("a plain json response becomes one segment spanning the clip")
    func plainJSONFallsBackToOneSegment() throws {
        let segments = try AudioTranscriptionClient.segments(
            from: Data(#"{"text": "hello there"}"#.utf8),
            fallbackDuration: 12.5
        )
        #expect(segments == [RawSegment(start: 0, end: 12.5, text: "hello there")])
    }

    @Test("punctuation-only output is dropped, like the local engines drop it")
    func noiseIsFiltered() throws {
        let json = #"{"segments": [{"start": 0, "end": 1, "text": " ... "}]}"#
        #expect(try AudioTranscriptionClient.segments(from: Data(json.utf8), fallbackDuration: 1).isEmpty)

        #expect(try AudioTranscriptionClient.segments(
            from: Data(#"{"text": "  "}"#.utf8), fallbackDuration: 1
        ).isEmpty)
    }

    @Test("a response that is not an object is an error, not empty output")
    func garbageThrows() {
        #expect(throws: OpenAICompatibleClient.ClientError.self) {
            try AudioTranscriptionClient.segments(from: Data("[]".utf8), fallbackDuration: 0)
        }
    }

    @Test("only format complaints trigger the plain-json retry")
    func verboseRejectionIsRecognised() {
        #expect(AudioTranscriptionClient.rejectsVerboseJSON(
            #"{"error":{"message":"response_format 'verbose_json' is not compatible"}}"#
        ))
        #expect(!AudioTranscriptionClient.rejectsVerboseJSON(
            #"{"error":{"message":"Incorrect API key provided"}}"#
        ))
    }

    // MARK: Synthesized WAV

    @Test("the test-connection clip is a real WAV")
    func silenceIsAValidWAV() throws {
        let data = AudioTranscriptionClient.wav([Float](repeating: 0, count: 1_600))
        let header = try #require(String(data: data.prefix(4), encoding: .ascii))

        #expect(header == "RIFF")
        // 44-byte header plus two bytes per sample.
        #expect(data.count == 44 + 1_600 * 2)
    }

    // MARK: Configuration

    @Test("the transcription URL is built like the chat one")
    func urlBuilding() {
        let provider = LLMProvider.openAITranscription
        #expect(provider.audioTranscriptionsURL?.absoluteString
            == "https://api.openai.com/v1/audio/transcriptions")

        let trailing = LLMProvider(name: "x", baseURL: "http://localhost:8080/v1/", model: "m")
        #expect(trailing.audioTranscriptionsURL?.absoluteString
            == "http://localhost:8080/v1/audio/transcriptions")
    }

    /// Every preset must be usable as-is once a key is entered; a preset with
    /// no model name is a preset that 400s on first use.
    @Test("transcription presets are complete")
    func presetsAreUsable() {
        for preset in LLMProvider.transcriptionPresets where preset.name != "Custom" {
            #expect(!preset.model.isEmpty, "\(preset.name) has no model")
            #expect(preset.audioTranscriptionsURL != nil, "\(preset.name) has no usable URL")
        }
    }

    @Test("the cloud engine reports itself as off-device")
    func cloudIsNotOnDevice() {
        #expect(!EngineKind.cloud.isOnDevice)
        #expect(EngineKind.whisperKit.isOnDevice)
        #expect(EngineKind.fluidAudio.isOnDevice)
    }

    /// Cloud ASR returns no speaker attribution, so labels have to come from a
    /// local diarizer. Losing this wiring would silently label everyone the
    /// same.
    @Test("the cloud engine borrows a local diarizer")
    func cloudDiarizesLocally() async {
        let diarizer = await EngineRegistry.shared.diarizer(for: ModelCatalog.cloudTranscription)
        #expect(diarizer is SpeakerKitDiarizer)
    }

    /// Two Whisper variants are two different sets of weights, and the registry
    /// exists so weights stay resident. Keyed by engine rather than by model,
    /// meetings and dictation on different variants would evict each other on
    /// every switch.
    @Test("each model gets its own cached engine")
    func enginesAreCachedPerModel() async {
        let turbo = await EngineRegistry.shared.transcriber(for: ModelCatalog.whisperTurbo)
        let distil = await EngineRegistry.shared.transcriber(for: ModelCatalog.distilWhisper)
        let turboAgain = await EngineRegistry.shared.transcriber(for: ModelCatalog.whisperTurbo)

        #expect(turbo is WhisperKitEngine)
        #expect(distil is WhisperKitEngine)
        #expect(turbo as AnyObject !== distil as AnyObject)
        #expect(turbo as AnyObject === turboAgain as AnyObject)

        let parakeet = await EngineRegistry.shared.transcriber(for: ModelCatalog.parakeet110M)
        #expect(parakeet is FluidAudioEngine)
    }

    @Test("preparing an unconfigured cloud engine fails before any upload")
    func unconfiguredEngineRefuses() async {
        let engine = CloudTranscriptionEngine(
            provider: LLMProvider(name: "Test", baseURL: "https://example.com/v1", model: "")
        )
        await #expect(throws: TranscriptionError.self) {
            try await engine.prepare(progress: nil)
        }
    }
}
