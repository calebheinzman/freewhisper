import AppKit
import FreeWhisperKit
import KeyboardShortcuts
import Observation

extension KeyboardShortcuts.Name {
    /// ⌃⌘4. The system's own screenshot shortcuts are ⇧⌘3/4/5 and their ⌃
    /// clipboard variants, so this sits next to them without colliding.
    ///
    /// Shipped through the library's `default:` rather than the one-shot
    /// "installed" flag the dictation hotkey used to use. That flag is what let
    /// the settings recorder clear the binding permanently with nothing on
    /// screen saying so; `default:` re-applies whenever the key is absent, so
    /// the worst case is a cleared shortcut coming back after a relaunch rather
    /// than a feature that can never be reached again.
    static let meetingScreenshot = Self(
        "meetingScreenshot",
        default: .init(.four, modifiers: [.control, .command])
    )
}

/// Global-hotkey screenshots filed into the meeting being recorded.
@Observable
@MainActor
final class ScreenshotController {
    /// Last thing that happened, for the Settings pane to show.
    private(set) var lastResult: String?

    @ObservationIgnored private let hud = ScreenshotHUD()
    @ObservationIgnored private let screenshots = ScreenshotStore.shared
    @ObservationIgnored private weak var coordinator: AppCoordinator?
    @ObservationIgnored private var isRegistered = false
    /// Guards against a held-down hotkey queueing a dozen captures.
    @ObservationIgnored private var isCapturing = false

    var shortcut: KeyboardShortcuts.Shortcut? {
        KeyboardShortcuts.getShortcut(for: .meetingScreenshot)
    }

    var scope: ScreenCapturer.Scope {
        UserDefaults.standard.bool(forKey: SettingsKeys.screenshotAllDisplays)
            ? .allDisplays
            : .displayWithPointer
    }

    func start(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        guard !isRegistered else { return }
        isRegistered = true

        KeyboardShortcuts.onKeyDown(for: .meetingScreenshot) { [weak self] in
            self?.capture()
        }
    }

    /// Capture now and attach it to whatever is recording.
    ///
    /// Deliberately does nothing outside a recording. Writing the file anyway
    /// would leave it somewhere the user has no way to find, and starting a
    /// recording off a screenshot key would be a surprising thing for a tool
    /// that records conversations to do.
    func capture() {
        guard !isCapturing else { return }

        guard let meeting = coordinator?.recordingMeeting else {
            hud.show(.notRecording)
            lastResult = "No recording in progress."
            return
        }

        switch Permissions.screenRecordingState() {
        case .authorized:
            break
        case .notDetermined:
            hud.show(.needsPermission)
            Permissions.requestScreenRecording()
            lastResult = "Waiting on Screen Recording permission."
            return
        case .denied:
            hud.show(.needsPermission)
            Permissions.openSettings(for: .screenRecording)
            lastResult = "Screen Recording permission is turned off."
            return
        }

        isCapturing = true

        // Timestamp before the capture, not after: ScreenCaptureKit can take a
        // beat to hand back several displays, and the moment the user pressed
        // the key is the moment they meant to mark.
        let offset = Date().timeIntervalSince(meeting.timelineOrigin)
        let scope = self.scope

        // Whatever is on screen now would otherwise be in the shot.
        hud.hide()

        Task {
            defer { isCapturing = false }
            do {
                let displays = try await ScreenCapturer.capture(scope: scope)
                let saved = try screenshots.append(
                    pngs: displays.map {
                        (data: $0.png, displayID: $0.displayID, pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight)
                    },
                    offset: offset,
                    meetingID: meeting.id
                )

                hud.show(.saved(timestamp: saved.timestampText))
                lastResult = "Saved a screenshot at \(saved.timestampText)."
                MeetingsModel.shared.screenshotsChanged(meetingID: meeting.id)
                Log.app.info("screenshot at \(Int(offset), privacy: .public)s into \(meeting.id, privacy: .public)")
            } catch ScreenshotError.permissionDenied {
                // Preflight passed but the capture was refused: the classic
                // sign of a grant that needs a relaunch to take effect.
                hud.show(.needsRestart)
                lastResult = "Restart FreeWhisper to finish enabling screenshots."
            } catch {
                hud.show(.failed(error.localizedDescription))
                lastResult = error.localizedDescription
                Log.app.error("screenshot failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
