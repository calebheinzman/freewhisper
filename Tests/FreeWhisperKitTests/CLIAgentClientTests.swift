import Foundation
import Testing

@testable import FreeWhisperKit

// MARK: - Argument construction

@Suite("CLI agent invocation")
struct CLIAgentInvocationTests {
    private static let resultFile = URL(fileURLWithPath: "/tmp/scratch/result.txt")

    private func invocation(
        tool: CLIAgentClient.Tool,
        model: String = "sonnet",
        system: String = "You summarize meetings.",
        user: String = "Speaker 1: the transcript"
    ) -> CLIAgentClient.Invocation {
        CLIAgentClient.invocation(
            tool: tool,
            model: model,
            system: system,
            user: user,
            resultFile: Self.resultFile
        )
    }

    @Test("claude runs one no-tool print turn with the user's config out of the way")
    func claudeArguments() {
        let arguments = invocation(tool: .claude).arguments

        #expect(arguments.first == "-p")
        #expect(arguments.contains("--system-prompt"))
        #expect(arguments.contains("--no-session-persistence"))
        #expect(arguments.contains("--disable-slash-commands"))
        #expect(arguments.contains("--strict-mcp-config"))

        // `--tools ""` is what makes this a single turn rather than an agent
        // loop, and the empty string is the argument, not a missing one.
        let tools = arguments.firstIndex(of: "--tools").map { arguments[arguments.index(after: $0)] }
        #expect(tools == "")

        let sources = arguments.firstIndex(of: "--setting-sources")
            .map { arguments[arguments.index(after: $0)] }
        #expect(sources == "")

        // --bare would force an API key and skip the keychain, which defeats
        // the entire point of this backend.
        #expect(!arguments.contains("--bare"))
    }

    /// The one that matters for privacy: `ps` shows every process's arguments
    /// to every user on the machine.
    @Test("the transcript never appears in the arguments", arguments: CLIAgentClient.Tool.allCases)
    func transcriptStaysOffTheCommandLine(tool: CLIAgentClient.Tool) {
        let secret = "Speaker 1: the acquisition closes on Tuesday"
        let invocation = invocation(tool: tool, user: secret)

        #expect(!invocation.arguments.contains { $0.contains("acquisition") })
        #expect(invocation.stdin.contains(secret))
    }

    @Test("claude takes the model alias, and omits the flag when there isn't one")
    func claudeModel() {
        let named = invocation(tool: .claude, model: "opus").arguments
        #expect(named.firstIndex(of: "--model").map { named[named.index(after: $0)] } == "opus")

        #expect(!invocation(tool: .claude, model: "").arguments.contains("--model"))
    }

    @Test("codex reads the prompt from stdin and writes its answer to a file")
    func codexArguments() {
        let invocation = invocation(tool: .codex, model: "")

        #expect(invocation.arguments.first == "exec")
        #expect(invocation.arguments.contains("--skip-git-repo-check"))
        #expect(invocation.arguments.contains("--ephemeral"))
        #expect(invocation.arguments.contains("--ignore-user-config"))

        let sandbox = invocation.arguments.firstIndex(of: "--sandbox")
            .map { invocation.arguments[invocation.arguments.index(after: $0)] }
        #expect(sandbox == "read-only")

        // stdout is a human-readable event stream, so the final message has to
        // come out of band.
        let out = invocation.arguments.firstIndex(of: "-o")
            .map { invocation.arguments[invocation.arguments.index(after: $0)] }
        #expect(out == Self.resultFile.path)
        #expect(invocation.resultFile == Self.resultFile)

        // No positional prompt at all — that is what makes codex read stdin.
        #expect(!invocation.arguments.contains("-"))
    }

    /// codex has no `--system-prompt`, so the instructions have to travel with
    /// the transcript or they are simply lost.
    @Test("codex folds the system prompt into stdin")
    func codexSystemPrompt() {
        let invocation = invocation(tool: .codex, system: "SYSTEM RULES", user: "TRANSCRIPT")

        #expect(!invocation.arguments.contains("SYSTEM RULES"))
        #expect(invocation.stdin.contains("SYSTEM RULES"))
        #expect(invocation.stdin.contains("TRANSCRIPT"))
    }

    @Test("an unrecognised executable name is rejected rather than guessed at")
    func toolDetection() {
        #expect(CLIAgentClient.Tool(executable: URL(fileURLWithPath: "/opt/homebrew/bin/claude")) == .claude)
        #expect(CLIAgentClient.Tool(executable: URL(fileURLWithPath: "/usr/local/bin/codex")) == .codex)
        #expect(CLIAgentClient.Tool(
            executable: URL(fileURLWithPath: "/opt/homebrew/Caskroom/claude-code/2.1.212/claude")
        ) == .claude)
        #expect(CLIAgentClient.Tool(executable: URL(fileURLWithPath: "/usr/bin/python3")) == nil)
    }
}

// MARK: - Output parsing

@Suite("CLI agent output")
struct CLIAgentOutputTests {
    /// The regression this whole method exists for. `claude --output-format
    /// json` wraps the answer in an envelope, and `Summarizer.parse` takes the
    /// *outermost* JSON object it finds — so if the envelope isn't unwrapped
    /// here, every summary comes back as `{"type":"result",…}` rendered as
    /// prose instead of a title and action items.
    @Test("the claude envelope is unwrapped, not passed through")
    func unwrapsEnvelope() throws {
        let stdout = """
        {"type":"result","subtype":"success","is_error":false,"duration_ms":4210,
         "result":"{\\"title\\":\\"Standup\\",\\"summary\\":\\"We shipped it.\\"}",
         "total_cost_usd":0.01}
        """

        let text = try CLIAgentClient.parseOutput(
            tool: .claude, stdout: stdout, stderr: "", resultFileContents: nil
        )

        #expect(text == #"{"title":"Standup","summary":"We shipped it."}"#)

        // And the thing that actually breaks if this is wrong:
        let summary = Summarizer.parse(text)
        #expect(summary.title == "Standup")
        #expect(summary.summary == "We shipped it.")
    }

    @Test("a leading line before the JSON doesn't lose the result")
    func toleratesPrefix() throws {
        let stdout = """
        warning: something on stderr's twin
        {"type":"result","subtype":"success","is_error":false,"result":"ok"}
        """
        #expect(try CLIAgentClient.parseOutput(
            tool: .claude, stdout: stdout, stderr: "", resultFileContents: nil
        ) == "ok")
    }

    @Test("an errored claude run throws instead of returning its message as a summary")
    func claudeError() {
        let stdout = """
        {"type":"result","subtype":"error_during_execution","is_error":true,
         "result":"Credit balance is too low"}
        """
        #expect(throws: CLIAgentClient.CLIAgentError.self) {
            try CLIAgentClient.parseOutput(
                tool: .claude, stdout: stdout, stderr: "", resultFileContents: nil
            )
        }
    }

    @Test("a non-success subtype throws even when is_error is absent")
    func claudeNonSuccessSubtype() {
        let stdout = #"{"type":"result","subtype":"error_max_turns","result":"partial"}"#
        #expect(throws: CLIAgentClient.CLIAgentError.self) {
            try CLIAgentClient.parseOutput(
                tool: .claude, stdout: stdout, stderr: "", resultFileContents: nil
            )
        }
    }

    @Test("unparseable claude output is an error, not an empty summary")
    func claudeGarbage() {
        #expect(throws: CLIAgentClient.CLIAgentError.self) {
            try CLIAgentClient.parseOutput(
                tool: .claude, stdout: "command not found", stderr: "", resultFileContents: nil
            )
        }
    }

    @Test("codex reads its answer from the result file and ignores the event stream")
    func codexResultFile() throws {
        let text = try CLIAgentClient.parseOutput(
            tool: .codex,
            stdout: "[2026-08-26] thinking…\n[2026-08-26] tokens used: 900",
            stderr: "",
            resultFileContents: "  {\"title\":\"Standup\"}  \n"
        )
        #expect(text == #"{"title":"Standup"}"#)
    }

    @Test("a missing codex result file throws rather than summarizing the event log")
    func codexMissingResultFile() {
        #expect(throws: CLIAgentClient.CLIAgentError.self) {
            try CLIAgentClient.parseOutput(
                tool: .codex, stdout: "some progress noise", stderr: "", resultFileContents: nil
            )
        }
    }

    /// A CLI prints its progress first and its complaint last.
    @Test("the error message keeps the tail, and prefers stderr")
    func errorMessageTail() {
        let message = CLIAgentClient.errorMessage(
            stdout: "ignored",
            stderr: "line one\nline two\nline three\nline four\nthe actual problem"
        )
        #expect(message.contains("the actual problem"))
        #expect(!message.contains("line one"))

        #expect(CLIAgentClient.errorMessage(stdout: "only stdout", stderr: "   ") == "only stdout")
    }
}

// MARK: - Discovery

@Suite("CLI agent discovery")
struct CLIAgentDiscoveryTests {
    private func makeExecutable(named name: String, in directory: URL, body: String = "#!/bin/sh\n") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test("finds a command on the search path")
    func findsOnSearchPath() throws {
        let directory = try TemporaryDirectory()
        _ = try makeExecutable(named: "claude", in: directory.url)

        let found = try CLIAgentClient.locate("claude", searching: ["/nonexistent", directory.url.path])
        #expect(found.lastPathComponent == "claude")
    }

    @Test("a command that isn't installed anywhere is a clear failure")
    func missingCommand() throws {
        let directory = try TemporaryDirectory()
        #expect(throws: CLIAgentClient.CLIAgentError.self) {
            try CLIAgentClient.locate("claude", searching: [directory.url.path])
        }
        #expect(throws: CLIAgentClient.CLIAgentError.self) {
            try CLIAgentClient.locate("", searching: [directory.url.path])
        }
    }

    /// An explicit path is an instruction, not a hint. Falling back to the
    /// search path would silently run a different binary than the one the user
    /// named, which is the opposite of what typing a path means.
    @Test("an explicit path is never second-guessed")
    func explicitPath() throws {
        let directory = try TemporaryDirectory()
        let real = try makeExecutable(named: "claude", in: directory.url)

        #expect(try CLIAgentClient.locate(real.path, searching: []).path == real.path)
        #expect(throws: CLIAgentClient.CLIAgentError.self) {
            try CLIAgentClient.locate("/nonexistent/bin/claude", searching: [directory.url.path])
        }
    }

    @Test("a file that isn't executable doesn't count as found")
    func nonExecutableIsIgnored() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("claude")
        try "not executable".write(to: url, atomically: true, encoding: .utf8)

        #expect(throws: CLIAgentClient.CLIAgentError.self) {
            try CLIAgentClient.locate("claude", searching: [directory.url.path])
        }
    }

    /// The bug this list exists to prevent: a `.app` launched from Finder gets
    /// launchd's PATH, which has no Homebrew in it.
    @Test("the search path covers the usual install locations regardless of PATH")
    func searchPathCoversHomebrew() {
        let path = CLIAgentClient.defaultSearchPath
        #expect(path.contains("/opt/homebrew/bin"))
        #expect(path.contains("/usr/local/bin"))
    }

    /// `claude` looks its keychain credential up by account name, so a child
    /// missing `USER` reports "Not logged in" while the same command works
    /// perfectly in a terminal — a failure that looks like a bug in this app.
    @Test("the child keeps the variables both CLIs find their credentials through")
    func environmentKeepsCredentialVariables() {
        let environment = CLIAgentClient.environment()
        #expect(environment["HOME"]?.isEmpty == false)
        #expect(environment["USER"]?.isEmpty == false)
        #expect(environment["PATH"]?.contains("/opt/homebrew/bin") == true)
    }
}

// MARK: - Authentication

@Suite("CLI agent authentication")
struct CLIAgentAuthTests {
    @Test("a signed-out claude is detected from its status JSON")
    func claudeSignedOut() {
        #expect(CLIAgentClient.isSignedOut(
            tool: .claude, status: 0, stdout: #"{"loggedIn":false}"#
        ))
        #expect(!CLIAgentClient.isSignedOut(
            tool: .claude, status: 0,
            stdout: #"{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max"}"#
        ))
    }

    /// Lenient on purpose: if these subcommands change shape, the feature
    /// should keep working rather than refuse to run over a parse failure.
    @Test("an unrecognisable status answer is not treated as signed out")
    func claudeUnknownStatus() {
        #expect(!CLIAgentClient.isSignedOut(tool: .claude, status: 0, stdout: "who knows"))
        #expect(!CLIAgentClient.isSignedOut(tool: .claude, status: 1, stdout: ""))
    }

    @Test("codex reports being signed out through its exit code")
    func codexSignedOut() {
        #expect(CLIAgentClient.isSignedOut(tool: .codex, status: 1, stdout: "Not logged in"))
        #expect(!CLIAgentClient.isSignedOut(tool: .codex, status: 0, stdout: "Logged in using ChatGPT"))
    }
}

// MARK: - Running a real subprocess

/// Drives the whole path — discovery, argv, pipes, parsing — against a stub
/// standing in for the real CLI, so the plumbing is covered without a billed
/// call to anyone.
@Suite("CLI agent process")
struct CLIAgentProcessTests {
    /// Writes a fake `claude` that captures what it was given and replies with
    /// whatever the test put in `stdout.json`.
    private func makeStub(
        named name: String,
        in directory: URL,
        script: String
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try ("#!/bin/sh\n" + script).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func provider(named name: String, command: URL, model: String = "") -> LLMProvider {
        LLMProvider(
            name: name,
            baseURL: "",
            model: model,
            backend: .cliAgent,
            command: command.path
        )
    }

    @Test("the transcript reaches the CLI on stdin and the answer comes back")
    func roundTrip() async throws {
        let directory = try TemporaryDirectory()
        let capture = directory.url.appendingPathComponent("stdin.txt")
        let argv = directory.url.appendingPathComponent("argv.txt")

        let stub = try makeStub(named: "claude", in: directory.url, script: """
        cat > "\(capture.path)"
        for arg in "$@"; do printf '%s\\n' "$arg"; done > "\(argv.path)"
        printf '%s' '{"type":"result","subtype":"success","is_error":false,"result":"the summary"}'
        """)

        let client = CLIAgentClient(provider: provider(named: "Claude Code", command: stub))
        let answer = try await client.complete(
            messages: [.system("SYSTEM"), .user("Speaker 1: hello there")],
            temperature: 0.2,
            maxTokens: nil
        )

        #expect(answer == "the summary")

        let stdin = try String(contentsOf: capture, encoding: .utf8)
        #expect(stdin.contains("Speaker 1: hello there"))
        // The system prompt travels as a flag for claude, not on stdin.
        #expect(!stdin.contains("SYSTEM"))
        #expect(try String(contentsOf: argv, encoding: .utf8).contains("--system-prompt"))
    }

    /// A transcript is far bigger than a pipe buffer (64 KB). If the parent
    /// wrote stdin without draining stdout at the same time, both sides would
    /// block forever and the summary would hang until the timeout.
    @Test("a transcript larger than the pipe buffer doesn't deadlock", .timeLimit(.minutes(1)))
    func largeInputDoesNotDeadlock() async throws {
        let directory = try TemporaryDirectory()
        let capture = directory.url.appendingPathComponent("stdin.txt")

        let stub = try makeStub(named: "claude", in: directory.url, script: """
        # Chatter on stdout *before* reading stdin, which is what makes this
        # deadlock if the parent isn't draining concurrently.
        i=0; while [ $i -lt 200 ]; do printf 'noise noise noise noise noise noise\\n'; i=$((i+1)); done
        cat > "\(capture.path)"
        printf '%s' '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
        """)

        let big = String(repeating: "Speaker 1: this is a long meeting.\n", count: 60_000)
        #expect(big.utf8.count > 2_000_000)

        let client = CLIAgentClient(provider: provider(named: "Claude Code", command: stub))
        let answer = try await client.complete(messages: [.user(big)], temperature: 0.2, maxTokens: nil)

        #expect(answer == "ok")
        let written = try FileManager.default.attributesOfItem(atPath: capture.path)[.size] as? Int
        #expect(written == big.utf8.count)
    }

    @Test("codex's answer is read from the -o file it was given")
    func codexResultFile() async throws {
        let directory = try TemporaryDirectory()
        let capture = directory.url.appendingPathComponent("stdin.txt")

        let stub = try makeStub(named: "codex", in: directory.url, script: """
        cat > "\(capture.path)"
        out=""; prev=""
        for arg in "$@"; do
          if [ "$prev" = "-o" ]; then out="$arg"; fi
          prev="$arg"
        done
        printf 'thinking...\\ntokens used: 900\\n'
        printf '%s' 'the codex summary' > "$out"
        """)

        let client = CLIAgentClient(provider: provider(named: "Codex", command: stub))
        let answer = try await client.complete(
            messages: [.system("SYSTEM"), .user("TRANSCRIPT")],
            temperature: 0.2,
            maxTokens: nil
        )

        #expect(answer == "the codex summary")

        // codex has no --system-prompt, so both parts have to arrive on stdin.
        let stdin = try String(contentsOf: capture, encoding: .utf8)
        #expect(stdin.contains("SYSTEM"))
        #expect(stdin.contains("TRANSCRIPT"))
    }

    @Test("a non-zero exit surfaces the CLI's own complaint")
    func failureCarriesMessage() async throws {
        let directory = try TemporaryDirectory()
        let stub = try makeStub(named: "claude", in: directory.url, script: """
        echo 'progress' >&2
        echo 'Invalid API key · Please run /login' >&2
        exit 1
        """)

        let client = CLIAgentClient(provider: provider(named: "Claude Code", command: stub))

        await #expect(throws: CLIAgentClient.CLIAgentError.self) {
            try await client.complete(messages: [.user("x")], temperature: 0.2, maxTokens: nil)
        }

        do {
            _ = try await client.complete(messages: [.user("x")], temperature: 0.2, maxTokens: nil)
            Issue.record("expected a failure")
        } catch let error as CLIAgentClient.CLIAgentError {
            #expect(error.localizedDescription.contains("Please run /login"))
        }
    }

    /// The stall guard. `maxTokens` can't be expressed on either CLI, so a
    /// wedged child has to be bounded by the clock or a summary never returns.
    @Test("a CLI that never finishes is killed", .timeLimit(.minutes(1)))
    func timeout() async throws {
        let directory = try TemporaryDirectory()
        let stub = try makeStub(named: "claude", in: directory.url, script: "sleep 120\n")

        let started = Date()
        await #expect(throws: CLIAgentClient.CLIAgentError.self) {
            _ = try await CLIAgentClient.run(
                executable: stub,
                arguments: [],
                stdin: "",
                workingDirectory: directory.url,
                timeout: 2
            )
        }
        #expect(Date().timeIntervalSince(started) < 30)
    }

    @Test("a command that isn't installed fails before anything is spawned")
    func missingCommandFails() async throws {
        let client = CLIAgentClient(provider: LLMProvider(
            name: "Claude Code", baseURL: "", model: "",
            backend: .cliAgent, command: "/nonexistent/claude"
        ))

        await #expect(throws: CLIAgentClient.CLIAgentError.self) {
            try await client.complete(messages: [.user("x")], temperature: 0.2, maxTokens: nil)
        }
    }

    @Test("a binary that is neither claude nor codex is refused")
    func unsupportedExecutable() async throws {
        let directory = try TemporaryDirectory()
        let stub = try makeStub(named: "summarizer", in: directory.url, script: "exit 0\n")

        let client = CLIAgentClient(provider: provider(named: "Custom", command: stub))
        await #expect(throws: CLIAgentClient.CLIAgentError.self) {
            try await client.complete(messages: [.user("x")], temperature: 0.2, maxTokens: nil)
        }
    }
}

// MARK: - Provider wiring

@Suite("CLI agent provider")
struct CLIAgentProviderTests {
    @Test("CLI providers route to the CLI client")
    func routing() {
        #expect(ChatClient.make(for: LLMProvider.claudeCode) is CLIAgentClient)
        #expect(ChatClient.make(for: LLMProvider.codex) is CLIAgentClient)
        #expect(!(ChatClient.make(for: LLMProvider.ollama) is CLIAgentClient))
    }

    /// The program runs on this Mac, but the model does not. A green "never
    /// leaves this Mac" label here would be a lie, and this repo would rather
    /// have no label than a label that can lie.
    @Test("a CLI agent is not local, however local the program is")
    func notLocal() {
        #expect(!LLMProvider.claudeCode.isLocal)
        #expect(!LLMProvider.codex.isLocal)
    }

    @Test("the privacy note names who receives the transcript, not the program")
    func destinationName() {
        #expect(LLMProvider.claudeCode.destinationName == "Anthropic")
        #expect(LLMProvider.codex.destinationName == "OpenAI")
        #expect(LLMProvider.ollama.destinationName == "Ollama")
    }

    @Test("CLI providers round-trip through JSON with their command intact")
    func encoding() throws {
        let encoded = try JSONEncoder().encode(LLMProvider.claudeCode)
        let decoded = try JSONDecoder().decode(LLMProvider.self, from: encoded)
        #expect(decoded == LLMProvider.claudeCode)
        #expect(decoded.command == "claude")
        #expect(decoded.resolvedBackend == .cliAgent)
    }

    /// `command` arrived after `backend` did, so there is a second generation of
    /// saved providers that predates it.
    @Test("a provider saved before `command` existed still decodes")
    func legacyDecode() throws {
        let legacy = Data("""
        {"name":"Ollama","baseURL":"http://localhost:11434/v1","model":"llama3.2",
         "backend":"openAICompatible"}
        """.utf8)

        let provider = try JSONDecoder().decode(LLMProvider.self, from: legacy)
        #expect(provider.command == nil)
        #expect(provider.resolvedBackend == .openAICompatible)
    }

    @Test("the presets are reachable by command name")
    func lookup() {
        #expect(LLMProvider.cliAgent(named: "claude") == LLMProvider.claudeCode)
        #expect(LLMProvider.cliAgent(named: " CODEX ") == LLMProvider.codex)
        #expect(LLMProvider.cliAgent(named: "gemini") == nil)
        #expect(LLMProvider.cliAgentPresets.count == 2)
    }

    /// Chunking costs a process launch per chunk against a model that could
    /// have taken the whole meeting in one request.
    @Test("CLI providers summarize long meetings in one call")
    func mapReduceThreshold() {
        #expect(Summarizer(provider: .claudeCode).mapReduceThreshold == Summarizer.cliMapReduceThreshold)
        #expect(Summarizer(provider: .codex).mapReduceThreshold == Summarizer.cliMapReduceThreshold)
        #expect(Summarizer(provider: .ollama).mapReduceThreshold == Summarizer.mapReduceThreshold)
        #expect(Summarizer.cliMapReduceThreshold > Summarizer.mapReduceThreshold)
    }
}

// MARK: - Helpers

/// A scratch directory that cleans up after itself.
private struct TemporaryDirectory: ~Copyable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-agent-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
