import Foundation

/// One prompt in, one completion out.
///
/// The summarizer does not care whether the model is a few hundred milliseconds
/// away over HTTP or running in this process on the GPU, so this is the seam:
/// ``OpenAICompatibleClient`` and ``LocalLLMEngine`` both fit through it.
public protocol ChatCompleting: Sendable {
    func complete(
        messages: [OpenAICompatibleClient.Message],
        temperature: Double,
        maxTokens: Int?
    ) async throws -> String
}

extension ChatCompleting {
    /// Cheap liveness check for the settings pane.
    public func testConnection() async throws -> String {
        try await complete(
            messages: [.user("Reply with the single word: ok")],
            temperature: 0,
            maxTokens: 10
        )
    }
}

public enum ChatClient {
    /// Resolves a provider to something that can answer prompts.
    public static func make(for provider: LLMProvider) -> any ChatCompleting {
        switch provider.resolvedBackend {
        case .openAICompatible:
            OpenAICompatibleClient(provider: provider)
        case .onDevice:
            LocalLLMEngine.shared.client(repoID: provider.model)
        }
    }
}
