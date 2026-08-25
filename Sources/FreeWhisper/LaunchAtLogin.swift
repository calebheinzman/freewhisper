import Foundation
import FreeWhisperKit
import ServiceManagement

/// Launch-at-login via SMAppService, the supported route since macOS 13.
///
/// A meeting detector that only runs when you remember to start it is not much
/// of a meeting detector, so this is worth offering — but it stays opt-in.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns whether the change took effect. macOS can put the service in
    /// `.requiresApproval`, where the user has to enable it in System Settings.
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return isEnabled == enabled
        } catch {
            Log.app.error("launch at login \(enabled ? "register" : "unregister") failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
