import ArgumentParser
import Foundation
import FreeWhisperKit

/// Headless driver for the FreeWhisper pipeline.
///
/// The GUI + TCC prompts + needing a live meeting makes for a miserable
/// development loop, so every stage of the pipeline is reachable from here.
/// Wrapper purely so the model-location migration runs once, before any
/// subcommand can ask whether a model is on disk. `fwctl` ships inside the app
/// bundle and can perfectly well be the first thing a user runs.
@main
struct FWCtlMain {
    static func main() async {
        ModelStorage.migrateFromDocumentsIfNeeded()
        await FWCtl.main()
    }
}

struct FWCtl: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fwctl",
        abstract: "Headless driver for the FreeWhisper pipeline.",
        subcommands: [
            Processes.self,
            Watch.self,
            Record.self,
            ListMeetings.self,
            Transcribe.self,
            Screenshot.self,
            Dictate.self,
            Summarize.self,
            Providers.self,
            Models.self,
        ]
    )
}

struct Processes: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ps",
        abstract: "List processes the CoreAudio HAL knows about."
    )

    @Flag(name: .shortAndLong, help: "Include processes that aren't currently using audio.")
    var all = false

    func run() throws {
        let processes = all
            ? AudioProcessMonitor.currentProcesses()
            : AudioProcessMonitor.activeProcesses()

        guard !processes.isEmpty else {
            print("no processes are using audio right now")
            return
        }

        print(row("PID", "MIC", "OUT", "APP", "BUNDLE ID"))
        for process in processes {
            print(row(
                String(process.pid),
                process.isRunningInput ? "yes" : "-",
                process.isRunningOutput ? "yes" : "-",
                process.name,
                process.bundleID ?? "-"
            ))
        }
    }

    private func row(_ pid: String, _ mic: String, _ out: String, _ app: String, _ bundle: String) -> String {
        pid.pad(6) + mic.pad(5) + out.pad(5) + app.pad(30) + bundle
    }
}

struct Watch: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Watch for meetings, using the same detector the app uses. Ctrl-C to stop."
    )

    @Option(help: "Seconds an app must hold the mic before it counts as a meeting.")
    var startDelay: Double = 6

    @Option(help: "Seconds the mic must stay released before a meeting ends.")
    var stopDelay: Double = 15

    @Option(
        name: .customLong("watch-app"),
        help: "Extra bundle ID prefix to treat as a meeting app. Repeatable."
    )
    var extraApps: [String] = []

    @Flag(help: "Also print every audio-process change, not just meetings.")
    var verbose = false

    func run() throws {
        // Long-running command: when stdout is a pipe or file it is block
        // buffered, so events would sit unflushed until the buffer filled or
        // the process exited cleanly — and a watcher is usually Ctrl-C'd.
        setvbuf(stdout, nil, _IONBF, 0)

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"

        let apps = KnownApps.defaults + extraApps.map {
            KnownApp(bundleIDPrefix: $0, kind: .other, displayName: $0)
        }
        let watcher = MeetingWatcher(
            settings: DetectionSettings(startDelay: startDelay, stopDelay: stopDelay),
            apps: apps
        )

        print("watching for meetings (start after \(startDelay)s of mic use, end after \(stopDelay)s)")
        print("known apps: " + apps.map(\.displayName).joined(separator: ", "))
        print("")

        watcher.start { event in
            let stamp = formatter.string(from: Date())
            switch event {
            case .meetingStarted(let meeting):
                print("[\(stamp)] STARTED  \(meeting.displayName) (pid \(meeting.pid))")
            case .meetingEnded(let meeting):
                print("[\(stamp)] ENDED    \(meeting.displayName)")
            }
        }

        let monitor = AudioProcessMonitor(interval: 2)
        if verbose {
            monitor.start { snapshots in
                let active = snapshots.filter { $0.isRunningInput || $0.isRunningOutput }
                let stamp = formatter.string(from: Date())
                let described = active.map { process -> String in
                    let flags = [
                        process.isRunningInput ? "mic" : nil,
                        process.isRunningOutput ? "out" : nil,
                    ].compactMap { $0 }.joined(separator: "+")
                    return "\(process.name)[\(flags)]"
                }
                print("[\(stamp)] audio: " + (described.isEmpty ? "(silence)" : described.joined(separator: "  ")))
            }
        }

        // Park forever on a semaphore rather than RunLoop.main.run() or
        // dispatchMain(). The run loop returns immediately when it has no input
        // sources — everything here is driven by GCD timers on their own queues
        // — and dispatchMain() requires the main thread, which ArgumentParser's
        // async root does not guarantee for a subcommand's run().
        //
        // withExtendedLifetime because both objects stop themselves in deinit,
        // and ARC may release a local right after its last use.
        withExtendedLifetime((watcher, monitor)) {
            DispatchSemaphore(value: 0).wait()
        }
    }
}

extension String {
    /// Left-align in a fixed column, truncating rather than wrapping.
    func pad(_ width: Int) -> String {
        if count >= width { return String(prefix(width - 1)) + " " }
        return self + String(repeating: " ", count: width - count)
    }
}
