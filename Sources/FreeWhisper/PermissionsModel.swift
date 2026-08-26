import Foundation
import FreeWhisperKit
import Observation

/// Live permission status for the menu bar panel.
@Observable
@MainActor
final class PermissionsModel {
    private(set) var states: [Permission: PermissionState] = [:]

    /// Required permissions that aren't granted — what the menu bar badges on.
    var blockingPermissions: [Permission] {
        Permission.allCases.filter { $0.isRequired && states[$0]?.isAuthorized != true }
    }

    var isReadyToRecord: Bool { blockingPermissions.isEmpty }

    func state(_ permission: Permission) -> PermissionState {
        states[permission] ?? .notDetermined
    }

    /// Refresh everything we can check without prompting. System audio is
    /// deliberately excluded: probing it *is* the prompt, so we show the last
    /// known answer until the user asks us to check again.
    func refresh() async {
        states[.microphone] = Permissions.microphoneState()
        states[.accessibility] = Permissions.accessibilityState()
        states[.screenRecording] = Permissions.screenRecordingState()
        if states[.systemAudio] == nil {
            states[.systemAudio] = Permissions.cachedSystemAudioState()
        }
        // "I granted it and the app still says no" is the single most common
        // support report for an app with five TCC prompts, and it is impossible
        // to diagnose from a screenshot. Log what the app actually sees, and
        // from which bundle, so the answer is one `log show` away.
        Log.app.notice("""
            permissions: \
            mic=\(String(describing: self.states[.microphone]), privacy: .public) \
            systemAudio=\(String(describing: self.states[.systemAudio]), privacy: .public) \
            accessibility=\(String(describing: self.states[.accessibility]), privacy: .public) \
            screenRecording=\(String(describing: self.states[.screenRecording]), privacy: .public) \
            bundle=\(Bundle.main.bundlePath, privacy: .public)
            """)
    }

    func request(_ permission: Permission) async {
        // Handled ahead of the switch because it is the one permission whose
        // prompt returns "no" immediately rather than when the user answers.
        // Falling through to the openSettings tail below would throw a System
        // Settings window on top of the dialog we just raised.
        if permission == .screenRecording {
            let alreadyAsked = Permissions.hasRequestedScreenRecording
            Permissions.requestScreenRecording()
            states[.screenRecording] = Permissions.screenRecordingState()
            if alreadyAsked, states[.screenRecording] != .authorized {
                Permissions.openSettings(for: .screenRecording)
            }
            return
        }

        switch permission {
        case .microphone:
            states[.microphone] = await Permissions.requestMicrophone()
        case .systemAudio:
            // Off the main actor deliberately. Probing means creating a real
            // process tap, and that call blocks until the user answers the TCC
            // dialog — on the main actor it freezes the whole UI, including the
            // panel the button lives in. `AppCoordinator.startRecording` hops off
            // for the same reason.
            states[.systemAudio] = await Task.detached { Permissions.probeSystemAudio() }.value
        case .accessibility:
            Permissions.requestAccessibility()
            // The user has to flip a switch in System Settings; we can only
            // re-read after they come back.
            states[.accessibility] = Permissions.accessibilityState()
        case .screenRecording:
            break // handled above
        }

        // A denied permission can't be re-prompted, so send them to the pane.
        if states[permission] == .denied {
            Permissions.openSettings(for: permission)
        }
    }
}
