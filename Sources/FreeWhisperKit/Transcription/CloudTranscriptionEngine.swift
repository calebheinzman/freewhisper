import Foundation

/// Transcription through any endpoint that speaks OpenAI's
/// `/v1/audio/transcriptions` shape — OpenAI, Groq, and the many services that
/// copied it.
///
/// Nothing is downloaded and nothing is cached, so unlike the local engines
/// this one has no warm-up cost and no weights on disk. What it costs instead
/// is that the audio leaves the machine, which the settings UI says plainly.
public actor CloudTranscriptionEngine: TranscriptionEngine {
    public nonisolated let kind = EngineKind.cloud

    private let provider: LLMProvider?
    private let session: URLSession

    /// `provider` defaults to whatever is configured, read at call time rather
    /// than at construction: `EngineRegistry` caches one instance of this for
    /// the life of the process, and a user who fixes their API key in Settings
    /// should not have to restart the app.
    public init(provider: LLMProvider? = nil, session: URLSession = .shared) {
        self.provider = provider
        self.session = session
    }

    private var configured: LLMProvider {
        provider ?? LLMSettings.transcriptionProvider
    }

    public func prepare(progress: ProgressHandler?) async throws {
        let provider = configured
        guard provider.audioTranscriptionsURL != nil else {
            throw TranscriptionError.engineFailed(
                engine: "Cloud",
                reason: OpenAICompatibleClient.ClientError.invalidURL(provider.baseURL)
                    .localizedDescription
            )
        }
        guard !provider.model.isEmpty else {
            throw TranscriptionError.engineFailed(
                engine: provider.name,
                reason: "No model is set. Choose one in Settings."
            )
        }
        if provider.keychainAccount != nil, !provider.isLocal,
           provider.apiKey?.isEmpty ?? true {
            throw TranscriptionError.engineFailed(
                engine: provider.name,
                reason: OpenAICompatibleClient.ClientError.missingAPIKey(provider.name)
                    .localizedDescription
            )
        }
    }

    public func transcribe(url: URL, progress: ProgressHandler?) async throws -> [RawSegment] {
        try await prepare(progress: progress)

        let provider = configured
        let client = AudioTranscriptionClient(provider: provider, session: session)
        let chunks = try WAVChunker.chunks(of: url)
        defer { WAVChunker.cleanUp(chunks) }

        var segments: [RawSegment] = []
        for (index, chunk) in chunks.enumerated() {
            progress?(.transcribing(fraction: Double(index) / Double(chunks.count)))
            do {
                let batch = try await client.transcribe(url: chunk.url)
                segments += batch.map {
                    RawSegment(
                        start: $0.start + chunk.offset,
                        end: $0.end + chunk.offset,
                        text: $0.text
                    )
                }
            } catch {
                // `ClientError` already phrases these for the user; anything
                // else is a transport failure whose description is the best
                // thing we have.
                throw TranscriptionError.engineFailed(
                    engine: provider.name,
                    reason: error.localizedDescription
                )
            }
        }

        progress?(.transcribing(fraction: 1))
        return segments.filter { $0.text.containsSpeech }
    }
}
