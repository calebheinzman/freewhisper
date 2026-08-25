import AppKit
import FreeWhisperKit
import SwiftUI

/// URL handling for a menu bar app.
///
/// `.onOpenURL` cannot be used here: the only always-present scene is the
/// `MenuBarExtra`, and its content view is not instantiated until the user opens
/// the panel, so the modifier never registers. The AppKit delegate callback
/// fires regardless of what SwiftUI has built.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the App scene so the delegate can open windows.
    var openMeetingsWindow: (() -> Void)?
    /// Set by the App scene so launch-time setup runs once, before any UI.
    var onLaunch: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        onLaunch?()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handle(url)
        }
    }

    /// `freewhisper://meetings` and `freewhisper://meetings?id=<meeting-id>`.
    private func handle(_ url: URL) {
        Log.app.notice("open URL: \(url.absoluteString, privacy: .public)")
        guard url.scheme == "freewhisper" else { return }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let target = url.host ?? components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard target == WindowID.meetings else { return }

        if let id = components?.queryItems?.first(where: { $0.name == "id" })?.value {
            MeetingsModel.shared.select(id: id)
        }
        openMeetingsWindow?()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
