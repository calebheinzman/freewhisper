import CoreAudio
import Foundation

/// One process's audio state at a point in time.
public struct AudioProcessSnapshot: Sendable, Equatable, Identifiable {
    public var id: pid_t { pid }

    public let pid: pid_t
    public let bundleID: String?
    public let name: String
    /// True while the process holds an input stream — i.e. it is using the mic.
    /// This is the signal meeting detection is built on.
    public let isRunningInput: Bool
    /// True while the process is playing audio.
    public let isRunningOutput: Bool

    public init(
        pid: pid_t,
        bundleID: String?,
        name: String,
        isRunningInput: Bool,
        isRunningOutput: Bool
    ) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.isRunningInput = isRunningInput
        self.isRunningOutput = isRunningOutput
    }
}

/// Polls the CoreAudio HAL for which processes are using audio right now.
///
/// Polling rather than property listeners is deliberate: listeners on
/// `kAudioProcessPropertyIsRunningInput` / `IsRunningOutput` are documented as
/// unreliable and frequently just don't fire. A 2s poll is cheap and correct.
///
/// Reading this list requires no permission — the microphone TCC prompt is only
/// triggered by actually opening an input stream.
public final class AudioProcessMonitor: @unchecked Sendable {
    public typealias Handler = ([AudioProcessSnapshot]) -> Void

    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "dev.freewhisper.process-monitor")
    private var timer: DispatchSourceTimer?
    private var handler: Handler?
    private var lastSnapshots: [AudioProcessSnapshot] = []
    private var pollCount = 0

    public init(interval: TimeInterval = 2.0) {
        self.interval = interval
    }

    deinit { stop() }

    public func start(handler: @escaping Handler) {
        queue.async {
            self.handler = handler
            self.timer?.cancel()

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: self.interval, leeway: .milliseconds(250))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
        }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    private func poll() {
        // PIDs get recycled; periodically forget what we think we know.
        pollCount += 1
        if pollCount % 150 == 0 { PIDResolver.invalidateCache() }

        let snapshots = Self.currentProcesses()
        guard snapshots != lastSnapshots else { return }
        lastSnapshots = snapshots
        handler?(snapshots)
    }

    /// Everything the HAL currently knows about, whether or not it is active.
    public static func currentProcesses() -> [AudioProcessSnapshot] {
        let address = AudioObjectPropertyAddress(kAudioHardwarePropertyProcessObjectList)
        guard let objectIDs = try? AudioObjectID.system.readArray(address, of: AudioObjectID.self) else {
            Log.audio.error("could not read process object list")
            return []
        }

        return objectIDs.compactMap { snapshot(for: $0) }
            .sorted { ($0.isRunningInput ? 0 : 1, $0.name) < ($1.isRunningInput ? 0 : 1, $1.name) }
    }

    /// Only the processes doing something with audio. This is what detection and
    /// the debug UI actually care about.
    public static func activeProcesses() -> [AudioProcessSnapshot] {
        currentProcesses().filter { $0.isRunningInput || $0.isRunningOutput }
    }

    private static func snapshot(for objectID: AudioObjectID) -> AudioProcessSnapshot? {
        guard let pid: pid_t = try? objectID.read(
            AudioObjectPropertyAddress(kAudioProcessPropertyPID)
        ), pid > 0 else { return nil }

        let isRunningInput = objectID.readBool(
            AudioObjectPropertyAddress(kAudioProcessPropertyIsRunningInput)
        )
        let isRunningOutput = objectID.readBool(
            AudioObjectPropertyAddress(kAudioProcessPropertyIsRunningOutput)
        )

        // Prefer the parent-walk: the HAL's own bundle ID for a Chrome renderer
        // is `com.google.Chrome.helper`, which nothing else in the app knows.
        let owner = PIDResolver.resolve(pid: pid)
        let bundleID = owner.bundleID ?? objectID.readOptionalString(
            AudioObjectPropertyAddress(kAudioProcessPropertyBundleID)
        )

        return AudioProcessSnapshot(
            pid: pid,
            bundleID: bundleID,
            name: owner.name,
            isRunningInput: isRunningInput,
            isRunningOutput: isRunningOutput
        )
    }
}
