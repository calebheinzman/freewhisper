import ArgumentParser
import Foundation
import FreeWhisperKit

/// Summarization scored on gold transcripts.
///
/// Text in, not audio: a summarizer fed a transcript full of ASR errors is being
/// marked down for the speech model's mistakes, and the two are chosen
/// separately in Settings. Feeding the human reference isolates the question the
/// table needs to answer — given a correct transcript, how good is the summary?
///
/// Calls ``Summarizer`` directly rather than `TranscriptionPipeline.summarize`,
/// because the pipeline's job on top is to persist the result and fold the
/// speaker names back into the transcript. Here the ``MeetingSummary`` itself is
/// the artifact being scored.
struct Summarize: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "summarize",
        abstract: "Summarize each gold transcript in a manifest."
    )

    @OptionGroup var options: CommonOptions

    @Flag(help: "Use a built-in on-device MLX model. --model is then its repo id.")
    var onDevice = false

    @Option(help: "Score a signed-in CLI agent: claude or codex. --model is then its model alias.")
    var cli: String?

    @Option(help: "Base URL for an OpenAI-compatible endpoint.")
    var baseURL: String = LLMProvider.ollama.baseURL

    @Option(help: "API key. Omit for local endpoints.")
    var apiKey: String?

    /// Only the HTTP path has a key to stash.
    private var usesEndpoint: Bool { !onDevice && cli == nil }

    func run() async throws {
        let manifest = try Manifest.load(options.manifest)
        let provider = try makeProvider()
        if let apiKey, usesEndpoint {
            provider.setAPIKey(apiKey)
        }
        defer { if apiKey != nil, usesEndpoint { Keychain.remove("fweval-temp") } }

        print("endpoint: \(describeTarget(provider))")
        print("model:    \(provider.model.isEmpty ? "(CLI default)" : provider.model)\n")

        let summarizer = Summarizer(provider: provider)

        // The first request pays for loading the weights; every one after it
        // does not. Priming with a trivial transcript keeps that cost out of the
        // per-item timings, the same way `prepare()` does on the speech tracks.
        let loading = Stopwatch()
        _ = try? await summarizer.summarize(transcript: Self.warmup)
        let loadSeconds = loading.seconds
        print("ready in \(String(format: "%.1fs", loadSeconds))\n")

        let run = try await Runner.each(
            manifest: manifest,
            model: options.model,
            out: options.out,
            force: options.force
        ) { item in
            guard let path = item.transcript else {
                throw ValidationError("item \(item.id) has no transcript")
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let transcript = try decoder.decode(Transcript.self, from: Data(contentsOf: URL(fileURLWithPath: path)))

            let clock = Stopwatch()
            let summary = try await summarizer.summarize(transcript: transcript)
            let wall = clock.seconds

            return ItemResult(
                id: item.id,
                model: options.model,
                dataset: manifest.dataset,
                track: manifest.track,
                summary: .init(summary),
                inputChars: transcript.plainText.count,
                wallSeconds: wall
            )
        }

        try Runner.finish(run, loadSeconds: loadSeconds, out: options.out)
    }

    private static let warmup = Transcript(
        segments: [TranscriptSegment(
            start: 0, end: 1, text: "Let's start.",
            channel: .system, speakerID: "speaker_0", speakerName: "Speaker 1"
        )],
        speakerNames: ["speaker_0": "Speaker 1"],
        engine: "warmup"
    )

    private func describeTarget(_ provider: LLMProvider) -> String {
        switch provider.resolvedBackend {
        case .onDevice: "on-device (MLX)"
        case .cliAgent: (CLIAgentClient.detect(provider.command ?? "")?.path ?? provider.command ?? "?")
        case .openAICompatible: baseURL
        }
    }

    private func makeProvider() throws -> LLMProvider {
        if let cli {
            guard var provider = LLMProvider.cliAgent(named: cli) else {
                throw ValidationError(
                    "Unknown CLI '\(cli)'. Options: "
                        + LLMProvider.cliAgentPresets.compactMap(\.command).joined(separator: ", ")
                )
            }
            // `options.model` always has a value here, so an explicit alias is
            // indistinguishable from the default — take it either way and let
            // the CLI reject a name it doesn't know.
            provider.model = options.model
            _ = try CLIAgentClient.locate(provider.command ?? cli)
            return provider
        }
        guard onDevice else {
            return LLMProvider(
                name: "fweval",
                baseURL: baseURL,
                model: options.model,
                keychainAccount: apiKey == nil ? nil : "fweval-temp"
            )
        }

        guard let built = ModelCatalog.summarizers.first(where: { $0.id == options.model }) else {
            throw ValidationError(
                "Unknown built-in model '\(options.model)'. Options: "
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
}
