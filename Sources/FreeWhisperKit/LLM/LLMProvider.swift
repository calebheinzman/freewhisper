import Foundation

/// How a provider is actually reached.
public enum LLMBackend: String, Codable, Sendable {
    /// An HTTP endpoint speaking the OpenAI shape.
    case openAICompatible
    /// Weights we downloaded ourselves, run in this process via MLX.
    case onDevice
    /// A coding-agent CLI already installed and signed in on this Mac, run as a
    /// subprocess so the user's existing subscription does the work.
    case cliAgent
}

/// Where to send text for summarization.
///
/// One config surface — base URL, model, optional key — covers Ollama, LM
/// Studio, OpenAI, Groq, OpenRouter and anything else that speaks the
/// OpenAI chat-completions shape, which is essentially everything. The same
/// struct also describes the built-in on-device model, where `model` holds a
/// HuggingFace repo id and `baseURL` goes unused, and the CLI agents, where
/// `command` names the executable and `baseURL` goes unused too.
public struct LLMProvider: Codable, Sendable, Equatable {
    public var name: String
    /// Base URL including the version path, e.g. `http://localhost:11434/v1`.
    public var baseURL: String
    /// Model name for HTTP endpoints; HuggingFace repo id when `backend` is
    /// `.onDevice`; the CLI's own model alias when `backend` is `.cliAgent`,
    /// where empty means "whatever that CLI defaults to".
    public var model: String
    /// Keychain account name, or nil for endpoints that need no key.
    public var keychainAccount: String?
    /// Optional, and read through ``resolvedBackend``, on purpose: providers
    /// persisted before this field existed decode into `nil`, and a
    /// non-optional property would make the synthesized decoder throw and
    /// silently reset everyone's configuration.
    public var backend: LLMBackend?
    /// Executable name or absolute path for `.cliAgent`, nil to search the
    /// usual install locations. Optional for the same migration reason as
    /// ``backend``.
    public var command: String?

    public init(
        name: String,
        baseURL: String,
        model: String,
        keychainAccount: String? = nil,
        backend: LLMBackend = .openAICompatible,
        command: String? = nil
    ) {
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.keychainAccount = keychainAccount
        self.backend = backend
        self.command = command
    }

    public var resolvedBackend: LLMBackend { backend ?? .openAICompatible }

    /// Whether a transcript sent to this provider stays on this machine.
    ///
    /// Computed from the endpoint every time it is read, never stored. It used
    /// to be a flag copied from the preset, which meant picking "Ollama" and then
    /// editing the endpoint to a remote host left the flag — and the green
    /// "transcripts never leave this Mac" label in Settings — asserting something
    /// false while transcripts went over the wire. The flag also waives the
    /// API-key requirement, so a stale `true` suppressed that check too.
    ///
    /// For a tool whose whole pitch is local-first, a privacy label that can lie
    /// is worse than no label at all.
    /// `.cliAgent` is deliberately *not* local. The program runs here, but it
    /// is a client for a hosted model: the transcript goes to Anthropic or
    /// OpenAI exactly as it would over HTTP. It falls out of the loopback check
    /// correctly — an empty `baseURL` has no host — but only by accident, so
    /// ``CLIAgentProviderTests`` pins it.
    public var isLocal: Bool {
        if resolvedBackend == .onDevice { return true }
        return Self.isLoopbackHost(baseURL)
    }

    /// Who actually reads a transcript sent here.
    ///
    /// Distinct from ``name`` because for the CLI agents those differ: "Claude
    /// Code" is a program on this Mac, and Anthropic is who receives the
    /// transcript. A privacy warning naming the program instead of the
    /// recipient would be telling the user the wrong thing.
    public var destinationName: String {
        switch name {
        case Self.claudeCode.name: "Anthropic"
        case Self.codex.name: "OpenAI"
        default: name
        }
    }

    /// Matches on the parsed host, not a substring: `contains("localhost")` also
    /// accepts `https://localhost.attacker.example/v1`, which is a real domain
    /// someone else controls.
    static func isLoopbackHost(_ urlString: String) -> Bool {
        guard let host = URLComponents(string: urlString)?.host?.lowercased() else { return false }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" {
            return true
        }
        // A .local name is mDNS on the LAN. Not this machine, but not the public
        // internet either; treated as local because the user runs that box.
        return host.hasSuffix(".local")
    }

    public var apiKey: String? {
        guard let keychainAccount else { return nil }
        return Keychain.get(keychainAccount)
    }

    public func setAPIKey(_ key: String?) {
        guard let keychainAccount else { return }
        Keychain.set(key, for: keychainAccount)
    }

    public var chatCompletionsURL: URL? {
        URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions")
    }

    public var audioTranscriptionsURL: URL? {
        URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/audio/transcriptions")
    }

    // MARK: Presets

    /// The default: weights we download and run ourselves, so summarization
    /// works on a fresh install without the user first going and installing a
    /// separate inference server.
    public static let onDevice = LLMProvider(
        name: "Built-in (on-device)",
        baseURL: "",
        model: ModelCatalog.defaultSummarizer.id,
        backend: .onDevice
    )

    /// Kept as the fallback for Intel Macs, where MLX cannot run.
    public static let ollama = LLMProvider(
        name: "Ollama",
        baseURL: "http://localhost:11434/v1",
        model: "llama3.2"
    )

    /// A frontier summarizer for anyone already paying for one.
    ///
    /// No API key and no endpoint: `claude` is already installed and already
    /// signed in, so the whole configuration is "which model". `model` is a
    /// CLI alias rather than a full name so it keeps meaning the current model
    /// as Anthropic ships new ones.
    public static let claudeCode = LLMProvider(
        name: "Claude Code",
        baseURL: "",
        model: "sonnet",
        backend: .cliAgent,
        command: "claude"
    )

    /// The same trade for a ChatGPT subscription. Empty `model` means whatever
    /// `codex` is configured to use, which is the useful default — unlike
    /// Claude Code it has no short stable aliases worth hardcoding.
    public static let codex = LLMProvider(
        name: "Codex",
        baseURL: "",
        model: "",
        backend: .cliAgent,
        command: "codex"
    )

    public static let presets: [LLMProvider] = [
        onDevice,
        claudeCode,
        codex,
        ollama,
        LLMProvider(
            name: "LM Studio",
            baseURL: "http://localhost:1234/v1",
            model: "local-model"
        ),
        LLMProvider(
            name: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            model: "gpt-4o-mini",
            keychainAccount: "openai"
        ),
        LLMProvider(
            name: "Groq",
            baseURL: "https://api.groq.com/openai/v1",
            model: "llama-3.3-70b-versatile",
            keychainAccount: "groq"
        ),
        LLMProvider(
            name: "OpenRouter",
            baseURL: "https://openrouter.ai/api/v1",
            model: "anthropic/claude-sonnet-4",
            keychainAccount: "openrouter"
        ),
        LLMProvider(
            name: "Custom",
            baseURL: "http://localhost:8080/v1",
            model: "",
            keychainAccount: "custom"
        ),
    ]

    /// The CLI presets, for the `--cli` flag on `fwctl` and `fweval` and for the
    /// Settings list. Derived from ``presets`` so there is one list to keep up
    /// to date, not two that can disagree.
    public static var cliAgentPresets: [LLMProvider] {
        presets.filter { $0.resolvedBackend == .cliAgent }
    }

    /// Looks a CLI preset up by its command name (`claude`, `codex`).
    public static func cliAgent(named name: String) -> LLMProvider? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return cliAgentPresets.first { $0.command == wanted }
    }

    // MARK: Transcription presets

    /// Endpoints for `/v1/audio/transcriptions`. A separate list from
    /// ``presets`` because the model names have nothing in common with the
    /// chat ones, but deliberately the same keychain accounts: a user with an
    /// OpenAI key should enter it once, not once per feature.
    public static let openAITranscription = LLMProvider(
        name: "OpenAI",
        baseURL: "https://api.openai.com/v1",
        model: "whisper-1",
        keychainAccount: "openai"
    )

    public static let transcriptionPresets: [LLMProvider] = [
        openAITranscription,
        LLMProvider(
            name: "Groq",
            baseURL: "https://api.groq.com/openai/v1",
            model: "whisper-large-v3-turbo",
            keychainAccount: "groq"
        ),
        LLMProvider(
            name: "Mistral",
            baseURL: "https://api.mistral.ai/v1",
            model: "voxtral-mini-latest",
            keychainAccount: "mistral"
        ),
        LLMProvider(
            name: "Fireworks",
            baseURL: "https://api.fireworks.ai/inference/v1",
            model: "whisper-v3-turbo",
            keychainAccount: "fireworks"
        ),
        LLMProvider(
            name: "Custom",
            baseURL: "http://localhost:8080/v1",
            model: "",
            keychainAccount: "custom-transcription"
        ),
    ]
}

/// Persisted provider selection.
public enum LLMSettings {
    private static let key = "llmProvider"
    private static let transcriptionKey = "transcriptionProvider"

    /// The built-in model on Apple Silicon, Ollama on Intel — where MLX cannot
    /// run and defaulting to it would offer something that can only fail.
    public static var fallbackProvider: LLMProvider {
        LocalLLMEngine.isSupported ? .onDevice : .ollama
    }

    public static var current: LLMProvider {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let provider = try? JSONDecoder().decode(LLMProvider.self, from: data)
            else { return fallbackProvider }
            return provider
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Where the `.cloud` transcription engine sends audio. Independent of
    /// ``current`` so a user can summarize locally while transcribing in the
    /// cloud, or the reverse.
    public static var transcriptionProvider: LLMProvider {
        get {
            guard let data = UserDefaults.standard.data(forKey: transcriptionKey),
                  let provider = try? JSONDecoder().decode(LLMProvider.self, from: data)
            else { return .openAITranscription }
            return provider
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: transcriptionKey)
        }
    }

    /// Whether summarization runs at all. Off means transcripts are produced
    /// but never sent anywhere, not even locally.
    public static var summarizationEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "summarizationEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "summarizationEnabled") }
    }
}
