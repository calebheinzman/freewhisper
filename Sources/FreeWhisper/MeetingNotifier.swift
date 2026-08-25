import Foundation
import FreeWhisperKit
import UserNotifications

/// The "a meeting was detected" notification, with Record / Not now actions.
///
/// Recording someone's conversation is not a neutral act, so detection never
/// silently starts a recording. The user is told what was detected, given a
/// countdown they can cancel, and can turn the countdown off entirely.
@MainActor
final class MeetingNotifier: NSObject {
    enum Response {
        case record
        case dismiss
    }

    static let shared = MeetingNotifier()

    private static let categoryID = "meeting-detected"
    private static let recordActionID = "record"
    private static let dismissActionID = "dismiss"
    private static let notificationID = "meeting-detected"

    var onResponse: ((Response) -> Void)?

    private override init() {
        super.init()
    }

    func register() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let record = UNNotificationAction(
            identifier: Self.recordActionID,
            title: "Record",
            options: [.foreground]
        )
        let dismiss = UNNotificationAction(
            identifier: Self.dismissActionID,
            title: "Not now",
            options: [.destructive]
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryID,
                actions: [record, dismiss],
                intentIdentifiers: [],
                options: []
            )
        ])
    }

    func notifyMeetingDetected(_ meeting: DetectedMeeting, autoStartIn seconds: Int) {
        let content = UNMutableNotificationContent()
        content.title = "\(meeting.displayName) detected"
        content.body = seconds > 0
            ? "Recording starts in \(seconds) seconds."
            : "Record this call?"
        content.categoryIdentifier = Self.categoryID
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: Self.notificationID,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func clear() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
    }
}

extension MeetingNotifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // The app is frontmost far less often than not, but when it is, the
        // banner still needs to appear — it's the consent prompt.
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        await MainActor.run {
            switch action {
            case Self.recordActionID, UNNotificationDefaultActionIdentifier:
                onResponse?(.record)
            case Self.dismissActionID:
                onResponse?(.dismiss)
            default:
                break
            }
        }
    }
}
