import AppKit
import FreeWhisperKit
import SwiftUI

/// Every screenshot from a meeting, in a row above the transcript.
///
/// Shown independently of the transcript so screenshots are there the moment a
/// call ends — before transcription has run, which is when a user is most likely
/// to want to check what they captured.
struct ScreenshotStrip: View {
    let screenshots: [MeetingScreenshot]
    let url: (ScreenshotImage) -> URL?
    let onSelect: (MeetingScreenshot) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(screenshots.count) screenshot\(screenshots.count == 1 ? "" : "s")")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(screenshots) { screenshot in
                        Button {
                            onSelect(screenshot)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .top, spacing: 4) {
                                    ForEach(screenshot.images) { image in
                                        ScreenshotThumbnail(image: image, url: url(image), height: 64)
                                    }
                                }
                                Text(screenshot.timestampText)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                    .monospacedDigit()
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Jump to \(screenshot.timestampText) in the transcript")
                    }
                }
                .padding(.horizontal, 14)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03))
    }
}

/// A screenshot in the transcript, at the point it was taken.
struct ScreenshotCard: View {
    let screenshot: MeetingScreenshot
    let url: (ScreenshotImage) -> URL?
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "photo")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text("Screenshot")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(screenshot.timestampText)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            HStack(alignment: .top, spacing: 6) {
                ForEach(screenshot.images) { image in
                    ScreenshotThumbnail(image: image, url: url(image), height: 150)
                        .onTapGesture { open(image) }
                        .help("Open full size")
                        .contextMenu {
                            Button("Open") { open(image) }
                            Button("Show in Finder") { reveal(image) }
                            Button("Copy") { copy(image) }
                            Divider()
                            Button("Delete Screenshot", role: .destructive, action: onDelete)
                        }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func open(_ image: ScreenshotImage) {
        guard let url = url(image) else { return }
        NSWorkspace.shared.open(url)
    }

    private func reveal(_ image: ScreenshotImage) {
        guard let url = url(image) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copy(_ image: ScreenshotImage) {
        guard let url = url(image), let nsImage = NSImage(contentsOf: url) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([nsImage])
    }
}
