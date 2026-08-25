import Foundation
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Runs a summarization model in this process, via MLX.
///
/// The point of this existing at all is that "summarize my meetings" should not
/// begin with "first install Ollama". The weights are ordinary MLX conversions
/// from HuggingFace, downloaded by ``ModelCatalog`` like any other model in the
/// app, and loaded from a directory we own.
public actor LocalLLMEngine {
    public static let shared = LocalLLMEngine()

    /// MLX is Metal on Apple Silicon and has no x86_64 path. Intel Macs keep
    /// the Ollama and cloud options instead.
    public nonisolated static var isSupported: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    /// One loaded model per repo, kept for the life of the process.
    ///
    /// Same reasoning as `EngineRegistry`: several gigabytes of weights take
    /// real seconds to page in, and a meeting that gets summarized in sections
    /// would otherwise pay that cost once per section.
    private var containers: [String: ModelContainer] = [:]

    private init() {}

    public nonisolated func client(repoID: String) -> any ChatCompleting {
        Client(repoID: repoID)
    }

    /// Frees the loaded weights. The next request reloads them.
    public func unload() {
        containers.removeAll()
    }

    func complete(
        repoID: String,
        messages: [OpenAICompatibleClient.Message],
        temperature: Double,
        maxTokens: Int?
    ) async throws -> String {
        let container = try await container(for: repoID)

        // The transport-level API is a message list, but a summarization call
        // is always "here are your instructions, here is the transcript". Fold
        // it back into that shape rather than replaying a conversation that
        // never happened.
        let instructions = messages
            .filter { $0.role == "system" }
            .map(\.content)
            .joined(separator: "\n\n")
        let prompt = messages
            .filter { $0.role != "system" }
            .map(\.content)
            .joined(separator: "\n\n")

        let session = ChatSession(
            container,
            instructions: instructions.isEmpty ? nil : instructions,
            generateParameters: GenerateParameters(
                maxTokens: maxTokens,
                temperature: Float(temperature)
            )
        )

        let response = try await session.respond(to: prompt)
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenAICompatibleClient.ClientError.emptyResponse
        }
        return trimmed
    }

    private func container(for repoID: String) async throws -> ModelContainer {
        if let existing = containers[repoID] { return existing }

        guard Self.isSupported else {
            throw LocalLLMError.unsupportedHardware
        }
        guard let model = ModelCatalog.summarizers.first(where: { $0.id == repoID }) else {
            throw LocalLLMError.unknownModel(repoID)
        }
        guard let weights = ModelCatalog.summarizerSnapshot(model) else {
            throw LocalLLMError.notDownloaded(model.name)
        }

        Log.llm.notice("loading on-device model \(repoID, privacy: .public)")
        let container = try await loadModelContainer(
            from: weights,
            using: #huggingFaceTokenizerLoader()
        )
        containers[repoID] = container
        return container
    }

    /// A `Sendable` handle so callers can hold "the on-device model" without
    /// holding the actor or its weights.
    private struct Client: ChatCompleting {
        let repoID: String

        func complete(
            messages: [OpenAICompatibleClient.Message],
            temperature: Double,
            maxTokens: Int?
        ) async throws -> String {
            try await LocalLLMEngine.shared.complete(
                repoID: repoID,
                messages: messages,
                temperature: temperature,
                maxTokens: maxTokens
            )
        }
    }
}

public enum LocalLLMError: LocalizedError {
    case unsupportedHardware
    case unknownModel(String)
    case notDownloaded(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedHardware:
            "The built-in model needs an Apple Silicon Mac. Use Ollama or a cloud provider instead."
        case .unknownModel(let id):
            "'\(id)' is not one of the built-in models."
        case .notDownloaded(let name):
            "\(name) hasn't been downloaded yet. Download it in Settings."
        }
    }
}
