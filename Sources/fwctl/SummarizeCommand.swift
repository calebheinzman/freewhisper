import ArgumentParser
import Foundation
import FreeWhisperKit

struct Summarize: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Summarize a transcribed meeting with any OpenAI-compatible endpoint."
    )

    @Argument(help: "Meeting ID (directory name), or 'latest'.")
    var meeting: String = "latest"

    @Flag(help: "Use the built-in on-device model instead of an HTTP endpoint.")
    var onDevice = false

    @Option(help: "Summarize with a signed-in CLI agent: claude or codex.")
    var cli: String?

    @Option(help: "Base URL, e.g. http://localhost:11434/v1")
    var baseURL: String = LLMProvider.ollama.baseURL

    @Option(help: "Model name, a built-in model id with --on-device, or a CLI model alias with --cli.")
    var model: String?

    @Option(help: "API key. Omit for local endpoints.")
    var apiKey: String?

    /// Only the HTTP path has a key to stash, so both the write and the cleanup
    /// have to agree on which paths are "HTTP".
    private var usesEndpoint: Bool { !onDevice && cli == nil }

    func run() async throws {
        let store = MeetingStore.shared
        let id = try resolveMeetingID(store: store)

        let provider = try makeProvider()
        if let apiKey, usesEndpoint {
            provider.setAPIKey(apiKey)
        }
        defer { if apiKey != nil, usesEndpoint { Keychain.remove("fwctl-temp") } }

        print("meeting:  \(id)")
        print("endpoint: \(describeTarget(provider))")
        print("model:    \(provider.model.isEmpty ? "(CLI default)" : provider.model)")
        print("")

        let started = Date()
        let pipeline = TranscriptionPipeline(store: store)
        let summary = try await pipeline.summarize(meetingID: id, provider: provider) { step in
            print("  \(step)")
        }

        print("\ntook \(String(format: "%.1f", Date().timeIntervalSince(started)))s\n")
        print(summary.markdown)
        print("written: \(store.paths(for: id).summary.path)")
    }

    private func describeTarget(_ provider: LLMProvider) -> String {
        switch provider.resolvedBackend {
        case .onDevice: "on-device (MLX)"
        case .cliAgent: (CLIAgentClient.detect(provider.command ?? "")?.path ?? provider.command ?? "?")
        case .openAICompatible: baseURL
        }
    }

    private func makeProvider() throws -> LLMProvider {
        if let cli {
            return try Self.cliProvider(named: cli, model: model)
        }
        guard onDevice else {
            return LLMProvider(
                name: "fwctl",
                baseURL: baseURL,
                model: model ?? LLMProvider.ollama.model,
                keychainAccount: apiKey == nil ? nil : "fwctl-temp"
            )
        }

        let id = model ?? ModelCatalog.defaultSummarizer.id
        guard let built = ModelCatalog.summarizers.first(where: { $0.id == id }) else {
            throw ValidationError(
                "Unknown built-in model '\(id)'. Options: "
                    + ModelCatalog.summarizers.map(\.id).joined(separator: ", ")
            )
        }
        guard ModelCatalog.isDownloaded(built) else {
            throw ValidationError(
                "\(built.name) isn't downloaded. Run `fwctl models --only \(built.id)` first."
            )
        }
        return LLMProvider(
            name: built.name,
            baseURL: "",
            model: built.id,
            backend: .onDevice
        )
    }

    /// Shared with `fweval`'s identical flag by shape, not by code — the two
    /// tools don't link each other, and a four-line lookup is not worth a
    /// module to hold it.
    static func cliProvider(named name: String, model: String?) throws -> LLMProvider {
        guard var provider = LLMProvider.cliAgent(named: name) else {
            throw ValidationError(
                "Unknown CLI '\(name)'. Options: "
                    + LLMProvider.cliAgentPresets.compactMap(\.command).joined(separator: ", ")
            )
        }
        if let model { provider.model = model }
        // Fail here rather than inside the pipeline, so the message names the
        // missing program instead of arriving as a failed summary.
        _ = try CLIAgentClient.locate(provider.command ?? name)
        return provider
    }

    private func resolveMeetingID(store: MeetingStore) throws -> String {
        guard meeting == "latest" else { return meeting }
        // "latest" should mean the newest thing worth summarizing, not the
        // newest recording — which may not be transcribed yet.
        guard let newest = store.list().first(where: { $0.status == .complete }) else {
            throw ValidationError("No transcribed meetings. Run `fwctl transcribe` first.")
        }
        return newest.id
    }
}

struct Providers: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the built-in provider presets."
    )

    func run() throws {
        print("SUMMARIZATION")
        for provider in LLMProvider.presets {
            print(row(provider))
        }
        print("\nTRANSCRIPTION")
        for provider in LLMProvider.transcriptionPresets {
            print(row(provider))
        }
    }

    private func row(_ provider: LLMProvider) -> String {
        let key = provider.keychainAccount == nil ? "no key needed" : "needs key"
        let locality = provider.isLocal ? "local" : "cloud"
        let target = switch provider.resolvedBackend {
        case .onDevice: provider.model
        // The resolved path, not the bare name: whether it was found at all is
        // the useful thing to print here.
        case .cliAgent: CLIAgentClient.detect(provider.command ?? "")?.path
            ?? "\(provider.command ?? "?") (not installed)"
        case .openAICompatible: provider.baseURL
        }
        return "\(provider.name.pad(22)) \(locality.pad(7)) \(key.pad(15)) \(target)"
    }
}
