import Foundation

/// Screenshots taken during a meeting, stored as PNGs in a `screenshots/`
/// subdirectory with a `screenshots.json` manifest beside the meeting's other
/// artifacts.
///
/// A sidecar rather than a field on `MeetingMetadata` for two reasons. The
/// recording session rewrites `meta.json` throughout the call, so a second
/// writer would clobber capture state; and synthesized `Decodable` throws on a
/// missing key, which — given `MeetingStore.load` swallows decode errors —
/// would make every meeting recorded before this feature silently disappear
/// from the list.
public final class ScreenshotStore: @unchecked Sendable {
    public static let shared = ScreenshotStore()

    private let store: MeetingStore
    private let fileManager = FileManager.default

    public init(store: MeetingStore = .shared) {
        self.store = store
    }

    // MARK: Reading

    /// Ordered by offset, so the caller can merge straight into the transcript.
    public func load(meetingID: String) -> [MeetingScreenshot] {
        let url = store.paths(for: meetingID).screenshotsManifest
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let screenshots = try? MeetingStore.makeDecoder().decode([MeetingScreenshot].self, from: data) else {
            Log.storage.error("could not read screenshots manifest for \(meetingID, privacy: .public)")
            return []
        }
        return screenshots.sorted { $0.offset < $1.offset }
    }

    /// Absolute location of an image, resolved against its meeting directory.
    public func url(for image: ScreenshotImage, meetingID: String) -> URL {
        store.paths(for: meetingID).directory.appendingPathComponent(image.relativePath)
    }

    // MARK: Writing

    /// Writes the PNGs and appends one entry to the manifest.
    ///
    /// `pngs` are display captures in screen order; each becomes one
    /// `ScreenshotImage`. Returns the entry that was recorded.
    @discardableResult
    public func append(
        pngs: [(data: Data, displayID: UInt32, pixelWidth: Int, pixelHeight: Int)],
        offset: TimeInterval,
        capturedAt: Date = Date(),
        meetingID: String
    ) throws -> MeetingScreenshot {
        guard !pngs.isEmpty else { throw ScreenshotError.nothingCaptured }

        let paths = store.paths(for: meetingID)
        try fileManager.createDirectory(at: paths.screenshotsDirectory, withIntermediateDirectories: true)

        let stem = MeetingScreenshot.filenameStem(offset: offset)
        var images: [ScreenshotImage] = []

        for (index, png) in pngs.enumerated() {
            // Two captures inside the same second would otherwise collide on the
            // filename and the second would overwrite the first.
            let name = uniqueName(in: paths.screenshotsDirectory, stem: stem, index: index + 1)
            let url = paths.screenshotsDirectory.appendingPathComponent(name)
            try png.data.write(to: url, options: .atomic)
            images.append(ScreenshotImage(
                relativePath: "screenshots/\(name)",
                displayID: png.displayID,
                pixelWidth: png.pixelWidth,
                pixelHeight: png.pixelHeight
            ))
        }

        let screenshot = MeetingScreenshot(offset: offset, capturedAt: capturedAt, images: images)
        var all = load(meetingID: meetingID)
        all.append(screenshot)
        try write(all, meetingID: meetingID)

        Log.storage.info("saved screenshot at \(Int(offset), privacy: .public)s for \(meetingID, privacy: .public)")
        return screenshot
    }

    /// Removes the entry *and* its PNGs — deleting has to actually delete.
    public func delete(id: UUID, meetingID: String) throws {
        var all = load(meetingID: meetingID)
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }

        let removed = all.remove(at: index)
        for image in removed.images {
            try? fileManager.removeItem(at: url(for: image, meetingID: meetingID))
        }
        try write(all, meetingID: meetingID)
    }

    private func write(_ screenshots: [MeetingScreenshot], meetingID: String) throws {
        let data = try MeetingStore.makeEncoder().encode(screenshots.sorted { $0.offset < $1.offset })
        try data.write(to: store.paths(for: meetingID).screenshotsManifest, options: .atomic)
    }

    private func uniqueName(in directory: URL, stem: String, index: Int) -> String {
        var suffix = 0
        while true {
            let name = suffix == 0
                ? "\(stem)-\(index).png"
                : "\(stem)-\(index)-\(suffix).png"
            if !fileManager.fileExists(atPath: directory.appendingPathComponent(name).path) {
                return name
            }
            suffix += 1
        }
    }
}

public enum ScreenshotError: LocalizedError {
    case nothingCaptured
    case noDisplays
    case permissionDenied
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .nothingCaptured: "Nothing was captured."
        case .noDisplays: "No displays were available to capture."
        case .permissionDenied: "FreeWhisper needs Screen Recording permission to take screenshots."
        case .encodingFailed: "The screenshot could not be encoded as a PNG."
        }
    }
}
