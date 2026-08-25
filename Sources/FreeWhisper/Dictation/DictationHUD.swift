import AppKit
import SwiftUI

/// Floating indicator shown while dictating.
///
/// A non-activating panel: it must never steal focus, because the whole point
/// is to type into whatever app the user is already in.
@MainActor
final class DictationHUD {
    private var panel: NSPanel?

    func show(controller: DictationController) {
        if panel == nil { panel = makePanel(controller: controller) }
        guard let panel else { return }
        position(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel(controller: DictationController) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 48),
            // .nonactivatingPanel is the critical bit — without it, showing the
            // HUD moves focus and the paste lands in the wrong app.
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
        // Visible over full-screen apps, and not captured in screen recordings
        // of other apps.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Excluded from screen capture, so a HUD that happens to be up when the
        // screenshot hotkey fires doesn't end up in the meeting notes.
        panel.sharingType = .none

        panel.contentView = NSHostingView(rootView: DictationHUDView(controller: controller))
        return panel
    }

    /// Bottom centre of the active screen — out of the way of text fields,
    /// which cluster in the upper two thirds.
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

private struct DictationHUDView: View {
    @Bindable var controller: DictationController

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                if case .listening = controller.state {
                    WaveformBars(level: controller.level)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 180, height: 48, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var icon: some View {
        switch controller.state {
        case .listening:
            Image(systemName: "mic.fill").foregroundStyle(.red)
        case .transcribing:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .idle:
            Image(systemName: "mic").foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch controller.state {
        case .listening: "Listening…"
        case .transcribing: "Transcribing…"
        case .failed: "Dictation failed"
        case .idle: "Ready"
        }
    }
}

/// Five bars that respond to the live input level, so a dead microphone is
/// obvious before the user finishes speaking into it.
private struct WaveformBars: View {
    let level: Float

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(Color.red.opacity(isLit(index) ? 0.9 : 0.2))
                    .frame(width: 3, height: height(index))
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }

    private func isLit(_ index: Int) -> Bool {
        Float(index) / 5 < level
    }

    private func height(_ index: Int) -> CGFloat {
        let base: [CGFloat] = [5, 9, 13, 9, 5]
        return isLit(index) ? base[index] : 4
    }
}
