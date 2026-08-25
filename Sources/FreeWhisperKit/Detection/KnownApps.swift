import Foundation

/// What kind of call an app represents, for labelling and for the notification.
public enum MeetingKind: String, Codable, Sendable, CaseIterable {
    case zoom
    case slackHuddle
    case teams
    case meet
    case webex
    case discord
    case facetime
    case browser
    case other

    public var displayName: String {
        switch self {
        case .zoom: "Zoom"
        case .slackHuddle: "Slack huddle"
        case .teams: "Teams"
        case .meet: "Google Meet"
        case .webex: "Webex"
        case .discord: "Discord"
        case .facetime: "FaceTime"
        case .browser: "Browser call"
        case .other: "Call"
        }
    }
}

/// An app worth watching for calls.
public struct KnownApp: Codable, Sendable, Equatable, Identifiable {
    /// Bundle identifier, matched case-insensitively as a prefix so helper
    /// processes like `com.google.Chrome.helper` resolve to their parent app.
    public var bundleIDPrefix: String
    public var kind: MeetingKind
    public var displayName: String
    public var isEnabled: Bool

    public var id: String { bundleIDPrefix }

    public init(bundleIDPrefix: String, kind: MeetingKind, displayName: String, isEnabled: Bool = true) {
        self.bundleIDPrefix = bundleIDPrefix
        self.kind = kind
        self.displayName = displayName
        self.isEnabled = isEnabled
    }
}

public enum KnownApps {
    /// Apps we watch by default.
    ///
    /// Slack is the point of the exercise. Slack exposes no huddle API and
    /// allows no bots, so calendar-based detection cannot see an ad-hoc huddle
    /// at all. But a huddle means the Slack process is holding the microphone,
    /// and that is observable without Slack's cooperation.
    public static let defaults: [KnownApp] = [
        KnownApp(bundleIDPrefix: "com.tinyspeck.slackmacgap", kind: .slackHuddle, displayName: "Slack"),
        KnownApp(bundleIDPrefix: "us.zoom.xos", kind: .zoom, displayName: "Zoom"),
        KnownApp(bundleIDPrefix: "com.microsoft.teams", kind: .teams, displayName: "Teams"),
        KnownApp(bundleIDPrefix: "com.cisco.webexmeetingsapp", kind: .webex, displayName: "Webex"),
        KnownApp(bundleIDPrefix: "com.webex.meetingmanager", kind: .webex, displayName: "Webex"),
        KnownApp(bundleIDPrefix: "com.hnc.Discord", kind: .discord, displayName: "Discord"),
        KnownApp(bundleIDPrefix: "com.apple.FaceTime", kind: .facetime, displayName: "FaceTime"),
        // Browsers cover Meet, Whereby, Around, Teams-on-web and everything
        // else that never ships a native app.
        KnownApp(bundleIDPrefix: "com.google.Chrome", kind: .browser, displayName: "Chrome"),
        KnownApp(bundleIDPrefix: "com.apple.Safari", kind: .browser, displayName: "Safari"),
        KnownApp(bundleIDPrefix: "company.thebrowser.Browser", kind: .browser, displayName: "Arc"),
        KnownApp(bundleIDPrefix: "com.microsoft.edgemac", kind: .browser, displayName: "Edge"),
        KnownApp(bundleIDPrefix: "org.mozilla.firefox", kind: .browser, displayName: "Firefox"),
        KnownApp(bundleIDPrefix: "com.brave.Browser", kind: .browser, displayName: "Brave"),
    ]

    /// Safari and other WebKit browsers route capture through a shared XPC
    /// service that launchd owns, so the parent walk lands on the service
    /// rather than the browser. Its process name still identifies the app.
    static let sharedMediaServiceBundleIDs: Set<String> = [
        "com.apple.WebKit.GPU",
        "com.apple.WebKit.WebContent",
    ]

    public static func match(_ snapshot: AudioProcessSnapshot, in apps: [KnownApp]) -> KnownApp? {
        guard let bundleID = snapshot.bundleID?.lowercased() else { return nil }

        if let direct = apps.first(where: { bundleID.hasPrefix($0.bundleIDPrefix.lowercased()) }) {
            return direct
        }

        // Fall back to the process name for shared media services.
        guard sharedMediaServiceBundleIDs.contains(snapshot.bundleID ?? "") else { return nil }
        let name = snapshot.name.lowercased()
        return apps.first { name.hasPrefix($0.displayName.lowercased()) }
    }
}
