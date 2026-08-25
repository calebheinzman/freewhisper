import ArgumentParser
import Foundation
import FreeWhisperKit

struct Screenshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Capture the screen into a meeting, the way the hotkey does."
    )

    @Argument(help: "Meeting ID (directory name), or 'latest'.")
    var meeting: String = "latest"

    @Option(help: "Seconds into the meeting to file it at. Defaults to now.")
    var at: Double?

    @Flag(help: "Capture only the display the pointer is on.")
    var pointerDisplayOnly = false

    @Flag(name: .shortAndLong, help: "List the meeting's screenshots instead of taking one.")
    var list = false

    func run() async throws {
        let store = MeetingStore.shared
        let screenshots = ScreenshotStore(store: store)

        let id = try resolveMeetingID(store: store)
        guard let metadata = store.load(id: id) else {
            throw ValidationError("No meeting named '\(id)'.")
        }

        if list {
            let existing = screenshots.load(meetingID: id)
            print("meeting: \(id)")
            print("\(existing.count) screenshot(s)")
            for screenshot in existing {
                let files = screenshot.images.map(\.relativePath).joined(separator: ", ")
                print(String(format: "  %8.2fs  %@", screenshot.offset, files))
            }
            return
        }

        guard Permissions.screenRecordingState().isAuthorized else {
            // Prompting from a CLI binary grants the permission to *this* binary,
            // not the app, so say what happened rather than silently failing.
            Permissions.requestScreenRecording()
            throw ValidationError(
                "Screen Recording permission is not granted for fwctl. Allow it in "
                    + "System Settings › Privacy & Security › Screen Recording, then rerun."
            )
        }

        let offset = at ?? Date().timeIntervalSince(metadata.timelineOrigin)
        let displays = try await ScreenCapturer.capture(
            scope: pointerDisplayOnly ? .displayWithPointer : .allDisplays
        )

        let saved = try screenshots.append(
            pngs: displays.map {
                (data: $0.png, displayID: $0.displayID, pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight)
            },
            offset: offset,
            meetingID: id
        )

        print("meeting: \(id)")
        print("at:      \(saved.timestampText) (\(String(format: "%.2f", saved.offset))s)")
        for image in saved.images {
            print("  \(image.relativePath)  \(image.pixelWidth)x\(image.pixelHeight)")
        }
    }

    private func resolveMeetingID(store: MeetingStore) throws -> String {
        guard meeting == "latest" else { return meeting }
        guard let newest = store.list().first else {
            throw ValidationError("No meetings recorded yet. Try `fwctl record` first.")
        }
        return newest.id
    }
}
