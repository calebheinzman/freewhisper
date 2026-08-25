import AVFoundation
import AppKit
import ApplicationServices
import CoreAudio
import Foundation
import UserNotifications

public enum PermissionState: String, Sendable {
    case authorized
    case denied
    /// Never asked, or (for system audio) not probed yet.
    case notDetermined

    public var isAuthorized: Bool { self == .authorized }
}

public enum Permission: String, CaseIterable, Sendable, Identifiable {
    case microphone
    case systemAudio
    case accessibility
    case screenRecording
    case notifications

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .microphone: "Microphone"
        case .systemAudio: "System Audio Recording"
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        case .notifications: "Notifications"
        }
    }

    public var rationale: String {
        switch self {
        case .microphone:
            "Records your side of a meeting, and your voice for dictation."
        case .systemAudio:
            "Records what the other people in the call are saying."
        case .accessibility:
            "Lets dictation type into whatever app you're in."
        case .screenRecording:
            "Lets the screenshot hotkey capture what's on screen into your notes."
        case .notifications:
            "Tells you when a meeting is detected, so recording is never a surprise."
        }
    }

    /// Whether the app is meaningfully broken without it.
    public var isRequired: Bool {
        switch self {
        case .microphone, .systemAudio: true
        case .accessibility, .screenRecording, .notifications: false
        }
    }

    /// Deep link into the right System Settings pane, for when the user has
    /// denied a permission and can no longer be re-prompted.
    public var settingsURL: URL? {
        let pane = switch self {
        case .microphone: "Privacy_Microphone"
        case .systemAudio: "Privacy_AudioCapture"
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        case .notifications: "Notifications"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
    }
}

public enum Permissions {
    // MARK: Microphone

    public static func microphoneState() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    public static func requestMicrophone() async -> PermissionState {
        if microphoneState() == .authorized { return .authorized }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        return granted ? .authorized : .denied
    }

    // MARK: System audio

    /// There is no public API to query the audio-capture permission, and the
    /// only documented way to check it is a private TCC framework we don't want
    /// to ship. So we probe: build a real process tap and throw it away. On the
    /// first run this is also what triggers the system prompt.
    ///
    /// Because probing *is* prompting, callers should treat this as a user
    /// action, not something to run on launch — hence the cached last-known
    /// result for display purposes.
    @discardableResult
    public static func probeSystemAudio() -> PermissionState {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "FreeWhisper permission probe"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)

        if status == noErr, tapID.isValid {
            AudioHardwareDestroyProcessTap(tapID)
            cacheSystemAudioState(.authorized)
            return .authorized
        }

        Log.audio.notice("system audio probe refused: \(CoreAudioError.fourCharCode(status), privacy: .public)")
        cacheSystemAudioState(.denied)
        return .denied
    }

    private static let systemAudioCacheKey = "permissions.systemAudio.lastKnown"

    public static func cachedSystemAudioState() -> PermissionState {
        guard let raw = UserDefaults.standard.string(forKey: systemAudioCacheKey),
              let state = PermissionState(rawValue: raw) else { return .notDetermined }
        return state
    }

    private static func cacheSystemAudioState(_ state: PermissionState) {
        UserDefaults.standard.set(state.rawValue, forKey: systemAudioCacheKey)
    }

    // MARK: Accessibility

    public static func accessibilityState() -> PermissionState {
        AXIsProcessTrusted() ? .authorized : .denied
    }

    /// Shows the system's "open System Settings" alert. macOS only presents it
    /// once per app version, so the UI also needs a direct settings link.
    public static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    // MARK: Screen recording

    /// Unlike system audio, this one has a real preflight API — it does not
    /// prompt, so it is safe to call on every refresh.
    ///
    /// CoreGraphics only answers yes or no, with no "never asked" in between, so
    /// we remember whether we have ever raised the prompt. Without that, a user
    /// who has simply not been asked yet is indistinguishable from one who said
    /// no, and the UI would offer to open System Settings for a switch that
    /// isn't there yet.
    public static func screenRecordingState() -> PermissionState {
        if CGPreflightScreenCaptureAccess() { return .authorized }
        return hasRequestedScreenRecording ? .denied : .notDetermined
    }

    private static let screenRecordingAskedKey = "permissions.screenRecording.asked"

    public static var hasRequestedScreenRecording: Bool {
        UserDefaults.standard.bool(forKey: screenRecordingAskedKey)
    }

    /// Prompts once per app, and the grant does **not** take effect in the
    /// running process — macOS requires a relaunch before captures return
    /// anything but black frames. Callers should say so rather than letting the
    /// user think it worked.
    @discardableResult
    public static func requestScreenRecording() -> Bool {
        UserDefaults.standard.set(true, forKey: screenRecordingAskedKey)
        return CGRequestScreenCaptureAccess()
    }

    // MARK: Notifications

    public static func notificationState() async -> PermissionState {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    public static func requestNotifications() async -> PermissionState {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        return granted ? .authorized : .denied
    }

    // MARK: Convenience

    public static func openSettings(for permission: Permission) {
        guard let url = permission.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }
}
