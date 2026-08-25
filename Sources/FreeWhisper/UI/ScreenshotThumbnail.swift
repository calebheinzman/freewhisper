import AppKit
import FreeWhisperKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Downsampled screenshots, kept in memory so scrolling doesn't re-decode them.
///
/// A full-screen Retina PNG is several megabytes and decodes to far more. Doing
/// that inside a SwiftUI `body` — which runs again on every redraw — is what
/// turns a meeting with twenty screenshots into a beachball, so thumbnails are
/// produced once at a size the UI actually shows and cached by image id.
@MainActor
final class ScreenshotThumbnailCache {
    static let shared = ScreenshotThumbnailCache()

    private var cache: [UUID: NSImage] = [:]
    /// In-flight loads, shared rather than skipped. The same screenshot is on
    /// screen twice — once in the filmstrip, once inline in the transcript — so
    /// both views ask for it in the same frame. Turning the second one away
    /// would leave it showing a placeholder forever, because nothing asks again.
    private var loads: [UUID: Task<NSImage?, Never>] = [:]

    func cached(_ image: ScreenshotImage) -> NSImage? { cache[image.id] }

    /// Loads and caches off the main actor, then hands back the thumbnail.
    func load(_ image: ScreenshotImage, at url: URL, maxPixelSize: Int = 480) async -> NSImage? {
        if let existing = cache[image.id] { return existing }

        let task = loads[image.id] ?? {
            let task = Task<NSImage?, Never>.detached(priority: .userInitiated) {
                Self.downsample(url: url, maxPixelSize: maxPixelSize)
            }
            loads[image.id] = task
            return task
        }()

        let thumbnail = await task.value
        loads[image.id] = nil
        if let thumbnail { cache[image.id] = thumbnail }
        return thumbnail
    }

    func forget(_ image: ScreenshotImage) {
        cache[image.id] = nil
        loads[image.id]?.cancel()
        loads[image.id] = nil
    }

    private nonisolated static func downsample(url: URL, maxPixelSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

/// One screenshot image, downsampled, with a placeholder while it loads.
struct ScreenshotThumbnail: View {
    let image: ScreenshotImage
    let url: URL?
    var height: CGFloat = 90

    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(0.06))
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .overlay {
                        Image(systemName: url == nil ? "questionmark" : "photo")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .task(id: image.id) {
            guard let url else { return }
            if let ready = ScreenshotThumbnailCache.shared.cached(image) {
                thumbnail = ready
            } else {
                thumbnail = await ScreenshotThumbnailCache.shared.load(image, at: url)
            }
        }
    }

    /// Reserve the right shape before the image arrives, so the transcript
    /// doesn't jump as thumbnails land.
    private var aspectRatio: CGFloat {
        guard image.pixelHeight > 0 else { return 16 / 9 }
        return CGFloat(image.pixelWidth) / CGFloat(image.pixelHeight)
    }
}
