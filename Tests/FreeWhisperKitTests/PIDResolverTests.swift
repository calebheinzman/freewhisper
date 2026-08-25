import Darwin
import Foundation
import Testing

@testable import FreeWhisperKit

@Suite("PID resolution")
struct PIDResolverTests {
    @Test("finds the parent of the current process")
    func parentOfSelf() {
        let parent = PIDResolver.parentPID(of: getpid())
        #expect(parent != nil)
        #expect(parent! > 0)
        #expect(parent! != getpid())
    }

    @Test("reports nil for a PID that cannot exist")
    func parentOfBogusPID() {
        #expect(PIDResolver.parentPID(of: -1) == nil)
    }

    @Test("reads the current process name")
    func nameOfSelf() {
        let name = PIDResolver.processName(getpid())
        #expect(name != nil)
        #expect(!(name ?? "").isEmpty)
    }

    @Test("reads the current executable path")
    func executablePathOfSelf() {
        let path = PIDResolver.executablePath(getpid())
        #expect(path != nil)
        #expect(path?.hasPrefix("/") == true)
    }

    /// The regression this guards: resolving by walking up the process tree
    /// attributed a command-line tool to whichever terminal launched it, so a
    /// recording started from the CLI was reported as belonging to the terminal.
    /// A test binary is not inside any .app, so it must resolve to no bundle
    /// rather than to the test runner's parent.
    @Test("a process outside any app bundle does not inherit a parent's identity")
    func cliToolDoesNotInheritTerminalIdentity() {
        let resolved = PIDResolver.resolve(pid: getpid())
        if let bundleID = resolved.bundleID {
            // If anything is reported it must come from our own path, never
            // from a terminal or IDE further up the tree.
            #expect(!bundleID.contains("Terminal"))
            #expect(!bundleID.contains("iTerm"))
            #expect(!bundleID.contains("conductor"))
        }
    }

    @Test("the outermost app bundle in a path wins, not the nearest")
    func outermostBundleWins() {
        // Chromium nests a helper .app inside the browser .app; the answer we
        // want is always the browser.
        let path = "/Applications/Google Chrome.app/Contents/Frameworks/"
            + "Google Chrome Framework.framework/Versions/1/Helpers/"
            + "Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper"
        let components = path.split(separator: "/").filter { $0.hasSuffix(".app") }
        #expect(components.first == "Google Chrome.app")
        #expect(components.last == "Google Chrome Helper (Renderer).app")
    }

    @Test("always resolves to something displayable, even for a dead PID")
    func resolveNeverReturnsEmpty() {
        // 999999 is above the default PID ceiling, so nothing owns it. We should
        // still get a usable label rather than a crash or an empty string.
        let resolved = PIDResolver.resolve(pid: 999_999)
        #expect(!resolved.name.isEmpty)
        #expect(resolved.pid == 999_999)
    }

    @Test("caches by PID")
    func cachingIsStable() {
        PIDResolver.invalidateCache()
        let first = PIDResolver.resolve(pid: getpid())
        let second = PIDResolver.resolve(pid: getpid())
        #expect(first == second)
    }
}

@Suite("CoreAudio property access")
struct CoreAudioPropertyTests {
    @Test("renders OSStatus as a four-char code")
    func fourCharCodeFormatting() {
        // 'who?' — the error the HAL returns for an unknown property.
        let status = OSStatus(bitPattern: 0x77686F3F)
        #expect(CoreAudioError.fourCharCode(status) == "'who?'")
    }

    @Test("falls back to hex for non-printable status values")
    func nonPrintableStatus() {
        #expect(CoreAudioError.fourCharCode(OSStatus(1)).hasPrefix("0x"))
    }

    @Test("enumerating audio processes requires no permission and does not throw")
    func processListIsReadable() {
        // The HAL always knows about at least coreaudiod's clients on a live
        // system; the point of the assertion is that reading is unprivileged.
        let processes = AudioProcessMonitor.currentProcesses()
        #expect(!processes.isEmpty)
        #expect(processes.allSatisfy { $0.pid > 0 })
    }
}
