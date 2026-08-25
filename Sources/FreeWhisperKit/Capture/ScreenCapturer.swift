import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// One display, captured.
public struct CapturedDisplay: Sendable {
    public var displayID: UInt32
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// PNG bytes, ready to write.
    public var png: Data
}

/// Full-screen capture via ScreenCaptureKit.
///
/// Deliberately thin: it cannot be exercised in a unit test — the screen
/// recording permission is a TCC grant tied to a signed, running app — so every
/// decision that *can* be tested (offsets, filenames, ordering, Markdown) lives
/// in `ScreenshotStore` and `Transcript` instead.
public enum ScreenCapturer {
    /// Whether to capture every display or only the one the pointer is on.
    public enum Scope: Sendable {
        case allDisplays
        case displayWithPointer
    }

    /// Captures now, returning one PNG per display in screen order.
    ///
    /// FreeWhisper's own windows are filtered out, so the confirmation HUD and
    /// the menu bar panel never end up in the shot.
    public static func capture(scope: Scope = .allDisplays) async throws -> [CapturedDisplay] {
        guard CGPreflightScreenCaptureAccess() else { throw ScreenshotError.permissionDenied }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        let displays = select(from: content.displays, scope: scope)
        guard !displays.isEmpty else { throw ScreenshotError.noDisplays }

        let ownApplications = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }

        var captured: [CapturedDisplay] = []
        for display in displays {
            let filter = SCContentFilter(
                display: display,
                excludingApplications: ownApplications,
                exceptingWindows: []
            )

            let configuration = SCStreamConfiguration()
            // Capture at the display's true backing resolution. The default is
            // point-sized, which on Retina throws away half the detail — and the
            // whole reason to screenshot a shared deck is to read it later.
            let scale = backingScale(for: display.displayID)
            configuration.width = Int(Double(display.width) * scale)
            configuration.height = Int(Double(display.height) * scale)
            configuration.captureResolution = .best
            configuration.showsCursor = false

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            guard let png = encodePNG(image) else { throw ScreenshotError.encodingFailed }
            captured.append(CapturedDisplay(
                displayID: display.displayID,
                pixelWidth: image.width,
                pixelHeight: image.height,
                png: png
            ))
        }

        return captured
    }

    private static func select(from displays: [SCDisplay], scope: Scope) -> [SCDisplay] {
        switch scope {
        case .allDisplays:
            return displays
        case .displayWithPointer:
            // NSEvent's mouse location is in the global coordinate space, which
            // is what NSScreen frames are in; SCDisplay only knows its id, so go
            // through NSScreen to find out which one the pointer is over.
            let location = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(location) } ?? NSScreen.main
            guard let id = screen?.displayID,
                  let match = displays.first(where: { $0.displayID == id })
            else {
                return displays.isEmpty ? [] : [displays[0]]
            }
            return [match]
        }
    }

    private static func backingScale(for displayID: CGDirectDisplayID) -> Double {
        let screen = NSScreen.screens.first { $0.displayID == displayID }
        return Double(screen?.backingScaleFactor ?? 2)
    }

    private static func encodePNG(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

extension NSScreen {
    /// The CoreGraphics display this screen is, for matching against
    /// ScreenCaptureKit's displays.
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
