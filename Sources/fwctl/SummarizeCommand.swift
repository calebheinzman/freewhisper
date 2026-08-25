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

    @Option(help: "Base URL, e.g. http://localhost:11434/v1")
    var baseURL: String = LLMProvider.ollama.baseURL

    @Option(help: "Model name, or a built-in model id with --on-device.")
    var model: String?

    @Option(help: "API key. Omit for local endpoints.")
    var apiKey: String?

    func run() async throws {
        let store = MeetingStore.shared
        let id = try resolveMeetingID(store: store)

        let provider = try makeProvider()
        if let apiKey, !onDevice {
            provider.setAPIKey(apiKey)
        }
        defer { if apiKey != nil, !onDevice { Keychain.remove("fwctl-temp") } }

        print("meeting:  \(id)")
        print("endpoint: \(onDevice ? "on-device (MLX)" : baseURL)")
        print("model:    \(provider.model)")
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

    private func makeProvider() throws -> LLMProvider {
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
        let target = provider.resolvedBackend == .onDevice ? provider.model : provider.baseURL
        return "\(provider.name.pad(22)) \(locality.pad(7)) \(key.pad(15)) \(target)"
    }
}
