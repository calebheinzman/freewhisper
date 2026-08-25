import FreeWhisperKit
import SwiftUI

@main
struct FreeWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var coordinator = AppCoordinator()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(coordinator: coordinator)
        } label: {
            Image(systemName: menuBarSymbol)
                .symbolRenderingMode(coordinator.phase.isRecording ? .multicolor : .monochrome)
                // The label view exists for the app's whole lifetime, unlike the
                // panel content, so this is a safe place to hand the delegate a
                // way to open windows.
                .onAppear {
                    appDelegate.openMeetingsWindow = openMeetings
                    coordinator.start()
                }
        }
        // .window rather than .menu so the panel can hold real controls
        // (toggles, meters, permission rows) instead of just menu items.
        .menuBarExtraStyle(.window)

        Window("Meetings", id: WindowID.meetings) {
            MeetingsWindow()
        }
        .defaultSize(width: 900, height: 560)

        Settings {
            SettingsView(coordinator: coordinator)
        }
    }

    private func openMeetings() {
        openWindow(id: WindowID.meetings)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private var menuBarSymbol: String {
        switch coordinator.phase {
        case .recording: "record.circle.fill"
        case .starting: "waveform.badge.magnifyingglass"
        case .meetingDetected: "waveform.badge.exclamationmark"
        case .processing: "waveform.badge.magnifyingglass"
        case .idle: coordinator.permissions.isReadyToRecord ? "waveform" : "waveform.badge.exclamationmark"
        }
    }
}

enum WindowID {
    static let meetings = "meetings"
}
