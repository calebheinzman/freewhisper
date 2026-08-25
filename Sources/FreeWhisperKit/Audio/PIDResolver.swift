import AppKit
import Darwin
import Foundation

/// Maps a raw PID to the user-visible app that owns it.
///
/// This exists because of Electron and Chromium. Slack plays huddle audio and
/// holds the microphone from `Slack Helper (Renderer)`, not from `Slack`, and
/// Chrome does the same for Meet. Attributing those to the wrong app means
/// missing the meeting.
public struct OwningApp: Sendable, Equatable {
    public let pid: pid_t
    public let bundleID: String?
    public let name: String

    public init(pid: pid_t, bundleID: String?, name: String) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
    }
}

public enum PIDResolver {
    private static let cacheLock = NSLock()
    private static var cache: [pid_t: OwningApp] = [:]

    public static func resolve(pid: pid_t) -> OwningApp {
        cacheLock.lock()
        if let hit = cache[pid] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        let resolved = uncachedResolve(pid: pid)

        cacheLock.lock()
        cache[pid] = resolved
        cacheLock.unlock()
        return resolved
    }

    /// PIDs are recycled, so anything long-lived should drop the cache
    /// periodically rather than trusting it forever.
    public static func invalidateCache() {
        cacheLock.lock()
        cache.removeAll()
        cacheLock.unlock()
    }

    private static func uncachedResolve(pid: pid_t) -> OwningApp {
        // The executable's path is the authoritative answer to "which app does
        // this process belong to", and it is right in both directions where
        // process-tree walking is wrong: a Chrome renderer lives inside
        // Chrome.app, while a command-line tool run from a terminal does not
        // live inside the terminal's bundle and must not inherit its identity.
        if let owner = owningAppFromExecutablePath(pid) {
            return owner
        }

        // No enclosing .app — an XPC service, a daemon, or a bare binary.
        // NSRunningApplication is the next best thing.
        if let app = NSRunningApplication(processIdentifier: pid), let bundleID = app.bundleIdentifier {
            return OwningApp(
                pid: pid,
                bundleID: bundleID,
                name: app.localizedName ?? processName(pid) ?? bundleID
            )
        }

        return OwningApp(pid: pid, bundleID: nil, name: processName(pid) ?? "pid \(pid)")
    }

    /// Walks the executable path for the *outermost* enclosing `.app`.
    ///
    /// Outermost rather than nearest on purpose. A Chrome renderer's path is
    /// `/Applications/Google Chrome.app/Contents/Frameworks/…/Google Chrome
    /// Helper (Renderer).app/Contents/MacOS/…`, and the nearest bundle is the
    /// helper — the answer we want is the browser that contains it.
    static func owningAppFromExecutablePath(_ pid: pid_t) -> OwningApp? {
        guard let path = executablePath(pid) else { return nil }

        var accumulated = ""
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            accumulated += "/" + component
            guard component.hasSuffix(".app") else { continue }
            guard let bundle = Bundle(path: accumulated),
                  let bundleID = bundle.bundleIdentifier else { continue }

            let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first?.localizedName
                ?? component.replacingOccurrences(of: ".app", with: "")
            return OwningApp(pid: pid, bundleID: bundleID, name: String(name))
        }
        return nil
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]

        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 4)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
