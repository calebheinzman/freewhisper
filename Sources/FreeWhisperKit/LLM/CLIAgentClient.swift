import Darwin
import Foundation

/// Summarizes by running a coding-agent CLI that is already installed and
/// already signed in on this Mac.
///
/// The point is the login, not the program. Someone paying for Claude Max or a
/// ChatGPT subscription has a frontier model sitting on their machine behind a
/// credential they have already granted; asking them to also paste an API key
/// and pay per token to summarize their own meetings is asking them to buy the
/// same thing twice. `claude -p` and `codex exec` are both one-shot,
/// text-in-text-out, and authenticate off that existing subscription, which
/// makes them a provider like any other from ``ChatCompleting``'s side.
///
/// Two deliberate constraints on how they are invoked:
///
/// - **The transcript goes on stdin, never in argv.** Arguments are visible in
///   `ps` to every user on the machine; a meeting transcript should not be.
/// - **Both are stripped of everything but the model.** Tools off, user
///   settings off, MCP servers off, skills off. A summarization call has no
///   business reading the user's files or inheriting their `CLAUDE.md`, and the
///   single no-tool turn is also much faster.
public struct CLIAgentClient: ChatCompleting {
    /// Which CLI we are talking to, which decides the whole argv.
    public enum Tool: String, Sendable, CaseIterable {
        case claude
        case codex

        /// Derived from the executable's filename rather than stored on the
        /// provider, so pointing the setting at a specific install
        /// (`/opt/homebrew/Caskroom/claude-code/2.1.212/claude`) still resolves
        /// to the right flags.
        public init?(executable: URL) {
            let name = executable.lastPathComponent.lowercased()
            if name.contains("claude") {
                self = .claude
            } else if name.contains("codex") {
                self = .codex
            } else {
                return nil
            }
        }
    }

    public enum CLIAgentError: LocalizedError {
        case notFound(String)
        case unsupportedTool(String)
        case notAuthenticated(String)
        case failed(command: String, status: Int32, message: String)
        case timedOut(command: String, seconds: Int)
        case emptyResponse(String)

        public var errorDescription: String? {
            switch self {
            case .notFound(let command):
                "Couldn't find '\(command)'. Run `which \(command)` in Terminal and put that path in Command."
            case .unsupportedTool(let name):
                "'\(name)' isn't a CLI this can drive. Point Command at `claude` or `codex`."
            case .notAuthenticated(let command):
                "\(command) isn't signed in. Run `\(command)` in Terminal and log in, then try again."
            case .failed(let command, let status, let message):
                message.isEmpty
                    ? "\(command) exited with code \(status)."
                    : "\(command): \(message.prefix(200))"
            case .timedOut(let command, let seconds):
                "\(command) didn't finish within \(seconds)s."
            case .emptyResponse(let command):
                "\(command) returned nothing."
            }
        }
    }

    /// Matches ``OpenAICompatibleClient``'s request timeout. It is doing the
    /// same job the token limits in ``Summarizer`` do for the on-device model —
    /// bounding a run that has stopped making progress — because neither CLI
    /// exposes a token cap to bound it any other way.
    static let timeout: TimeInterval = 300
    /// Short, because it is a local credential check, not a model call.
    static let authTimeout: TimeInterval = 30

    private let provider: LLMProvider

    public init(provider: LLMProvider) {
        self.provider = provider
    }

    // MARK: Completion

    /// `temperature` and `maxTokens` are ignored: neither CLI exposes them.
    /// Honouring them is not possible, and failing on them would mean this
    /// backend could not be used by the caller that passes them, so the
    /// wall-clock timeout stands in for the stall guard `maxTokens` provides
    /// elsewhere.
    public func complete(
        messages: [OpenAICompatibleClient.Message],
        temperature: Double = 0.2,
        maxTokens: Int? = nil
    ) async throws -> String {
        let executable = try Self.locate(commandName)
        guard let tool = Tool(executable: executable) else {
            throw CLIAgentError.unsupportedTool(executable.lastPathComponent)
        }

        let system = messages.filter { $0.role == "system" }
            .map(\.content).joined(separator: "\n\n")
        let user = messages.filter { $0.role != "system" }
            .map(\.content).joined(separator: "\n\n")

        // A scratch directory, so neither tool picks up whatever repository or
        // CLAUDE.md happens to sit at the app's working directory.
        let workingDirectory = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let invocation = Self.invocation(
            tool: tool,
            model: provider.model,
            system: system,
            user: user,
            resultFile: workingDirectory.appendingPathComponent("result.txt")
        )

        let clock = Date()
        let result = try await Self.run(
            executable: executable,
            arguments: invocation.arguments,
            stdin: invocation.stdin,
            workingDirectory: workingDirectory,
            timeout: Self.timeout
        )
        Log.llm.notice(
            """
            \(tool.rawValue, privacy: .public) finished in \
            \(String(format: "%.1f", Date().timeIntervalSince(clock)), privacy: .public)s \
            (exit \(result.status, privacy: .public))
            """
        )

        guard result.status == 0 else {
            throw CLIAgentError.failed(
                command: tool.rawValue,
                status: result.status,
                message: Self.errorMessage(stdout: result.stdout, stderr: result.stderr)
            )
        }

        let resultFileContents = invocation.resultFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        return try Self.parseOutput(
            tool: tool,
            stdout: result.stdout,
            stderr: result.stderr,
            resultFileContents: resultFileContents
        )
    }

    /// Overrides the protocol default so the Settings button can tell the three
    /// failures apart: not installed, installed but signed out, and installed
    /// and signed in but the call itself failed. "Test connection" saying
    /// *"exited with code 1"* when the real answer is *"log in"* is the
    /// difference between a fixable problem and a mystery.
    public func testConnection() async throws -> String {
        let executable = try Self.locate(commandName)
        guard let tool = Tool(executable: executable) else {
            throw CLIAgentError.unsupportedTool(executable.lastPathComponent)
        }
        try await Self.checkAuthentication(tool: tool, executable: executable)

        return try await complete(
            messages: [.user("Reply with the single word: ok")],
            temperature: 0,
            maxTokens: 10
        )
    }

    /// The configured command, falling back to the one that matches the preset
    /// so a provider saved without an explicit path still runs.
    private var commandName: String {
        let configured = provider.command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !configured.isEmpty { return configured }
        return provider.name == LLMProvider.codex.name ? Tool.codex.rawValue : Tool.claude.rawValue
    }

    // MARK: Invocation

    public struct Invocation: Sendable, Equatable {
        public let arguments: [String]
        public let stdin: String
        /// Where the tool was told to write its final message, for tools that
        /// do not put it on stdout on its own.
        public let resultFile: URL?
    }

    static func invocation(
        tool: Tool,
        model: String,
        system: String,
        user: String,
        resultFile: URL
    ) -> Invocation {
        switch tool {
        case .claude:
            var arguments = ["-p"]
            if !system.isEmpty { arguments += ["--system-prompt", system] }
            if !model.isEmpty { arguments += ["--model", model] }
            arguments += [
                // A single JSON object on stdout, which also carries whether the
                // run errored — `text` gives no way to tell a refusal from a
                // summary.
                "--output-format", "json",
                // One no-tool turn. Nothing to read, nothing to write, no loop.
                "--tools", "",
                "--permission-mode", "dontAsk",
                "--no-session-persistence",
                // The user's own CLAUDE.md, skills, hooks and MCP servers have
                // nothing to do with summarizing a meeting, and inheriting them
                // would make the result depend on unrelated configuration.
                "--disable-slash-commands",
                "--strict-mcp-config",
                "--setting-sources", "",
            ]
            // Deliberately no `--bare`: it skips keychain reads and forces an
            // API key, which is the one thing this whole backend exists to
            // avoid.
            return Invocation(arguments: arguments, stdin: user, resultFile: nil)

        case .codex:
            var arguments = ["exec"]
            if !model.isEmpty { arguments += ["-m", model] }
            arguments += [
                "--sandbox", "read-only",
                "--skip-git-repo-check",
                "--ephemeral",
                // Drops the user's config.toml and execpolicy rules. Auth still
                // resolves from CODEX_HOME, so this costs nothing.
                "--ignore-user-config",
                "--ignore-rules",
                "--color", "never",
                // stdout is a human-readable event stream, so the final message
                // has to come out of band to be parseable.
                "-o", resultFile.path,
            ]
            // No prompt argument at all: codex reads its instructions from stdin
            // when none is given, which keeps the transcript out of argv without
            // depending on how `-` parses.
            let prompt = system.isEmpty ? user : system + "\n\n" + user
            return Invocation(arguments: arguments, stdin: prompt, resultFile: resultFile)
        }
    }

    // MARK: Output

    static func parseOutput(
        tool: Tool,
        stdout: String,
        stderr: String,
        resultFileContents: String?
    ) throws -> String {
        switch tool {
        case .claude:
            // Reuses the summarizer's brace scanner rather than decoding stdout
            // whole, so a stray line before the object doesn't lose the result.
            guard let object = Summarizer.extractJSONObject(from: stdout),
                  let data = object.data(using: .utf8),
                  let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                throw CLIAgentError.emptyResponse(tool.rawValue)
            }

            // The envelope wraps the answer, so it has to be unwrapped *here*.
            // Handing it straight to `Summarizer.parse` would find this object's
            // braces first and return the envelope as the summary.
            let text = (envelope["result"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let failed = (envelope["is_error"] as? Bool) == true
                || (envelope["subtype"] as? String).map { $0 != "success" } == true
            if failed {
                throw CLIAgentError.failed(
                    command: tool.rawValue,
                    status: 0,
                    message: text.isEmpty ? (envelope["subtype"] as? String ?? "") : text
                )
            }

            guard !text.isEmpty else { throw CLIAgentError.emptyResponse(tool.rawValue) }
            return text

        case .codex:
            let text = (resultFileContents ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                let detail = errorMessage(stdout: stdout, stderr: stderr)
                throw detail.isEmpty
                    ? CLIAgentError.emptyResponse(tool.rawValue)
                    : CLIAgentError.failed(command: tool.rawValue, status: 0, message: detail)
            }
            return text
        }
    }

    /// Prefers stderr, falls back to stdout, and keeps the *tail* — a CLI puts
    /// its progress first and its complaint last.
    static func errorMessage(stdout: String, stderr: String) -> String {
        let candidate = stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? stdout
            : stderr
        let lines = candidate
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.suffix(3).joined(separator: " ")
    }

    // MARK: Discovery

    /// Where these CLIs actually install, in the order worth trying.
    ///
    /// This list is why the feature works at all. A `.app` launched from Finder
    /// inherits launchd's `PATH` — `/usr/bin:/bin:/usr/sbin:/sbin` — which does
    /// not contain Homebrew, so resolving `claude` through the environment
    /// succeeds in a terminal and then fails for every user who launches the
    /// app the normal way.
    static var defaultSearchPath: [String] {
        let home = NSHomeDirectory()
        let environmentPath = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }

        return environmentPath + [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.claude/local",
            "\(home)/.bun/bin",
            "\(home)/.npm-global/bin",
            "/opt/homebrew/opt/node/bin",
        ]
    }

    public static func locate(_ command: String) throws -> URL {
        try locate(command, searching: defaultSearchPath)
    }

    static func locate(_ command: String, searching directories: [String]) throws -> URL {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CLIAgentError.notFound(command) }

        // An explicit path is an instruction, not a hint: don't fall back to
        // searching if it's wrong, or the user gets a silently different binary.
        if trimmed.contains("/") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            guard FileManager.default.isExecutableFile(atPath: expanded) else {
                throw CLIAgentError.notFound(trimmed)
            }
            return URL(fileURLWithPath: expanded)
        }

        for directory in directories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(trimmed)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw CLIAgentError.notFound(trimmed)
    }

    /// The resolved path, or nil — for the Settings field's placeholder, which
    /// wants to show what was found without treating "nothing" as an error.
    public static func detect(_ command: String) -> URL? {
        try? locate(command)
    }

    // MARK: Authentication

    /// Cheap and unbilled: both CLIs can report their login state without
    /// calling a model.
    ///
    /// Lenient by design. Only a definite "not logged in" throws; an
    /// unparseable answer means these subcommands changed shape, and refusing
    /// to run on that basis would break the feature over cosmetics.
    static func checkAuthentication(tool: Tool, executable: URL) async throws {
        let arguments: [String]
        switch tool {
        case .claude: arguments = ["auth", "status"]
        case .codex: arguments = ["login", "status"]
        }

        guard let result = try? await run(
            executable: executable,
            arguments: arguments,
            stdin: "",
            workingDirectory: FileManager.default.temporaryDirectory,
            timeout: authTimeout
        ) else { return }

        if isSignedOut(tool: tool, status: result.status, stdout: result.stdout) {
            throw CLIAgentError.notAuthenticated(tool.rawValue)
        }
    }

    static func isSignedOut(tool: Tool, status: Int32, stdout: String) -> Bool {
        switch tool {
        case .claude:
            // Prints JSON: {"loggedIn": true, "authMethod": "claude.ai", ...}
            guard let object = Summarizer.extractJSONObject(from: stdout),
                  let data = object.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let loggedIn = json["loggedIn"] as? Bool
            else { return false }
            return !loggedIn
        case .codex:
            // Prints "Logged in using ChatGPT" and exits non-zero when not.
            return status != 0
        }
    }

    // MARK: Running

    struct ProcessResult: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Blocking pipe I/O belongs on its own threads, not on the cooperative
    /// pool — four of the five operations below sit in `read`/`write`/`wait`
    /// for the whole run.
    private static let ioQueue = DispatchQueue(
        label: "dev.freewhisper.cli-agent",
        attributes: .concurrent
    )

    static func run(
        executable: URL,
        arguments: [String],
        stdin: String,
        workingDirectory: URL,
        timeout: TimeInterval
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment()

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        // Without this, a child that exits before reading the transcript kills
        // *us* with SIGPIPE mid-write. Scoped to the one descriptor, so the
        // write just fails with EPIPE instead.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        // Run before any read: a bad executable throws here, and starting the
        // drains first would leave them blocked on a pipe nobody will close.
        try process.run()

        let box = RunBox(process: process)
        let timeoutWork = DispatchWorkItem { box.timeOut() }
        ioQueue.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

        let result: ProcessResult = await withTaskCancellationHandler {
            // All three concurrently: a transcript is far larger than a pipe
            // buffer, so writing it while the child writes back would deadlock
            // if nothing were draining.
            async let stdoutData = readToEnd(output.fileHandleForReading)
            async let stderrData = readToEnd(errors.fileHandleForReading)
            async let written: Void = write(stdin, to: input.fileHandleForWriting)

            _ = await written
            let status = await waitForExit(process)
            return ProcessResult(
                status: status,
                stdout: String(data: await stdoutData, encoding: .utf8) ?? "",
                stderr: String(data: await stderrData, encoding: .utf8) ?? ""
            )
        } onCancel: {
            box.kill()
        }

        timeoutWork.cancel()

        if box.didTimeOut {
            throw CLIAgentError.timedOut(
                command: executable.lastPathComponent,
                seconds: Int(timeout)
            )
        }
        try Task.checkCancellation()
        return result
    }

    /// Guards every touch of a `Process` after launch behind one lock.
    /// `terminate()` on a process that has already been reaped traps, and the
    /// timeout timer, the cancellation handler and the exit path all race for
    /// the same object.
    private final class RunBox: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private var timedOut = false

        init(process: Process) { self.process = process }

        var didTimeOut: Bool {
            lock.lock()
            defer { lock.unlock() }
            return timedOut
        }

        func timeOut() {
            lock.lock()
            timedOut = true
            lock.unlock()
            kill()
        }

        func kill() {
            lock.lock()
            defer { lock.unlock() }
            guard process.isRunning else { return }
            let pid = process.processIdentifier
            process.terminate()
            // SIGTERM is a request. Give it a moment to be honoured, then stop
            // asking — a wedged CLI must not hold the summary open forever.
            CLIAgentClient.ioQueue.asyncAfter(deadline: .now() + 5) {
                Darwin.kill(pid, SIGKILL)
            }
        }
    }

    /// Inherits the user's environment rather than building a clean one: both
    /// CLIs find their credentials through `HOME`, and `claude` shells out to
    /// tools that need a usable `PATH`.
    ///
    /// `USER` is filled in for the same reason `HOME` is, and it is not
    /// theoretical: `claude` looks its keychain credential up by account name,
    /// so a child without `USER` reports *"Not logged in · Please run /login"*
    /// while the very same command works in a terminal. launchd does set both
    /// for a Finder-launched app, so this is insurance rather than a fix — but
    /// the failure it prevents looks exactly like a bug in this app.
    static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if environment["HOME"] == nil { environment["HOME"] = NSHomeDirectory() }
        if environment["USER"] == nil { environment["USER"] = NSUserName() }
        if environment["LOGNAME"] == nil { environment["LOGNAME"] = NSUserName() }

        var seen = Set<String>()
        let path = defaultSearchPath.filter { seen.insert($0).inserted }
        environment["PATH"] = path.joined(separator: ":")
        return environment
    }

    private static func makeScratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                let data = (try? handle.readToEnd()) ?? Data()
                try? handle.close()
                continuation.resume(returning: data)
            }
        }
    }

    private static func write(_ text: String, to handle: FileHandle) async {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                if let data = text.data(using: .utf8), !data.isEmpty {
                    try? handle.write(contentsOf: data)
                }
                // The close is what tells the child there is no more input.
                // Skipping it hangs every one of these tools.
                try? handle.close()
                continuation.resume()
            }
        }
    }

    private static func waitForExit(_ process: Process) async -> Int32 {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus)
            }
        }
    }
}
