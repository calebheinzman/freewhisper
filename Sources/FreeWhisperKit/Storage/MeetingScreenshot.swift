import Foundation

/// One captured display, as a PNG inside the meeting directory.
public struct ScreenshotImage: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// Path relative to the meeting directory, e.g. `screenshots/000165-1.png`.
    ///
    /// Relative rather than absolute so the meeting folder stays a self-contained
    /// unit the user can move, back up or hand to someone else — the same
    /// property the rest of the storage layer is built around.
    public var relativePath: String
    public var displayID: UInt32
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(
        id: UUID = UUID(),
        relativePath: String,
        displayID: UInt32,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.id = id
        self.relativePath = relativePath
        self.displayID = displayID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// One press of the screenshot hotkey: the same instant across every display.
///
/// Grouped rather than one entry per display so a two-monitor capture reads as a
/// single moment in the transcript instead of two coincidental ones.
public struct MeetingScreenshot: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// Seconds from `MeetingMetadata.timelineOrigin`, so it sits on the same
    /// timeline as the transcript's segment timestamps.
    public var offset: TimeInterval
    public var capturedAt: Date
    public var images: [ScreenshotImage]

    public init(
        id: UUID = UUID(),
        offset: TimeInterval,
        capturedAt: Date = Date(),
        images: [ScreenshotImage]
    ) {
        self.id = id
        self.offset = offset
        self.capturedAt = capturedAt
        self.images = images
    }

    /// `2:45`, matching how the transcript labels a speaker turn.
    public var timestampText: String { Transcript.timestamp(offset) }

    /// Zero-padded whole seconds, used to name the files so the screenshots
    /// directory sorts chronologically as plain strings.
    static func filenameStem(offset: TimeInterval) -> String {
        String(format: "%06d", max(0, Int(offset)))
    }
}
