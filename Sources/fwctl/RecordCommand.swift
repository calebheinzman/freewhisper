import ArgumentParser
import Foundation
import FreeWhisperKit

struct Record: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Record mic + system audio to a meeting directory."
    )

    @Option(name: .shortAndLong, help: "How long to record, in seconds.")
    var seconds: Double = 15

    @Flag(help: "Skip the microphone stream.")
    var noMic = false

    @Flag(help: "Skip the system audio stream.")
    var noSystem = false

    @Option(help: "Label for the recording directory.")
    var label: String = "fwctl"

    func run() throws {
        let session = try RecordingSession(detectedApp: label)
        try session.start(captureMicrophone: !noMic, captureSystemAudio: !noSystem)

        print("recording to \(session.paths.directory.path)")
        if let error = session.metadata.micError {
            print("  ! mic: \(error)")
        }
        if let error = session.metadata.systemAudioError {
            print("  ! system: \(error)")
        }
        print("")

        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            // Sleeping on the main thread is fine here: the capture callbacks
            // run on their own audio queues.
            Thread.sleep(forTimeInterval: 0.25)
            let status = session.status()
            let line = "  \(Self.meter("mic", status.micLevel, active: status.micActive))"
                + "   \(Self.meter("sys", status.systemLevel, active: status.systemActive))"
                + "   \(String(format: "%4.1fs", status.duration))"
            print(line + "\u{1B}[K\r", terminator: "")
            fflush(stdout)
        }
        print("")

        let metadata = session.stop()
        print("\nstopped after \(String(format: "%.1f", metadata.duration))s")
        Self.report(session.paths.micAudio, label: "mic", expected: metadata.hasMicAudio)
        Self.report(session.paths.systemAudio, label: "system", expected: metadata.hasSystemAudio)

        if let error = metadata.micError { print("  ! mic: \(error)") }
        if let error = metadata.systemAudioError { print("  ! system: \(error)") }
        print("\nmeta: \(session.paths.metadata.path)")
    }

    /// A crude bar so you can see at a glance that audio is actually arriving —
    /// the whole point of this command. `level` is already dB-scaled to 0...1.
    private static func meter(_ name: String, _ level: Float, active: Bool) -> String {
        guard active else { return "\(name) [   off    ]" }
        let filled = Int(min(1, max(0, level)) * 10)
        let bar = String(repeating: "#", count: filled) + String(repeating: ".", count: 10 - filled)
        return "\(name) [\(bar)]"
    }

    private static func report(_ url: URL, label: String, expected: Bool) {
        guard expected else {
            print("  \(label): not captured")
            return
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let kb = ((attributes?[.size] as? Int) ?? 0) / 1024
        print("  \(label): \(url.lastPathComponent) (\(kb) KB)")
    }
}
