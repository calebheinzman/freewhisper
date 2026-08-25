import AppKit
import SwiftUI

/// A one-line confirmation that appears where the dictation HUD does, for about
/// a second, and never takes focus.
///
/// Feedback matters more here than it looks: the capture itself is invisible —
/// no shutter, no flash — so without this the user has no way to tell a saved
/// screenshot from a hotkey that did nothing.
@MainActor
final class ScreenshotHUD {
    enum Message {
        case saved(timestamp: String)
        case notRecording
        case needsPermission
        case needsRestart
        case failed(String)

        var icon: String {
            switch self {
            case .saved: "photo.badge.checkmark"
            case .notRecording: "record.circle.slash"
            case .needsPermission, .needsRestart: "lock.circle"
            case .failed: "exclamationmark.triangle.fill"
            }
        }

        var text: String {
            switch self {
            case .saved(let timestamp): "Screenshot saved · \(timestamp)"
            case .notRecording: "No recording in progress"
            case .needsPermission: "Allow Screen Recording to capture"
            case .needsRestart: "Restart FreeWhisper to finish enabling"
            case .failed(let reason): reason
            }
        }

        var tint: Color {
            switch self {
            case .saved: .green
            case .notRecording: .secondary
            case .needsPermission, .needsRestart, .failed: .orange
            }
        }

        /// Errors need longer on screen than a confirmation does.
        var duration: TimeInterval {
            if case .saved = self { return 1.2 }
            return 2.6
        }
    }

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    func show(_ message: Message) {
        dismissTask?.cancel()

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: ScreenshotHUDView(message: message))
        panel.setContentSize(NSSize(width: 260, height: 44))
        position(panel)
        panel.orderFrontRegardless()

        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(message.duration))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
    }

    /// Whether anything is on screen right now — the controller hides the HUD
    /// before capturing so a previous confirmation can't end up in the shot.
    var isVisible: Bool { panel?.isVisible ?? false }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 44),
            // .nonactivatingPanel so a confirmation never pulls focus out of the
            // meeting the user is in.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Belt and braces with the capture filter: excluded from screen capture
        // entirely, so it cannot appear in a screenshot or anyone's screen share.
        panel.sharingType = .none
        return panel
    }

    /// Bottom centre, matching the dictation HUD so the two never fight over the
    /// same spot in the user's attention.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 90
        ))
    }
}

private struct ScreenshotHUDView: View {
    let message: ScreenshotHUD.Message

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: message.icon)
                .font(.system(size: 14))
                .foregroundStyle(message.tint)
            Text(message.text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
