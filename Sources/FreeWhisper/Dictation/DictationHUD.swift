import AppKit
import SwiftUI

/// Floating indicator shown while dictating.
///
/// A non-activating panel: it must never steal focus, because the whole point
/// is to type into whatever app the user is already in.
@MainActor
final class DictationHUD {
    private var panel: NSPanel?

    /// One source of truth for the size: it has to agree with the SwiftUI frame
    /// below or the material background and the panel edge stop lining up.
    static let size = NSSize(width: 200, height: 48)

    func show(controller: DictationController) {
        if panel == nil { panel = makePanel(controller: controller) }
        guard let panel else { return }
        // Only on the way in. The controller polls this at 10 Hz, and re-ordering
        // the window to the front ten times a second was harmless while the panel
        // ignored the mouse — now that there is a button in it, doing so in the
        // middle of a click is a good way to lose the click.
        guard !panel.isVisible else { return }
        position(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel(controller: DictationController) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
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
        // The cancel button needs clicks, so the panel can no longer wave them
        // through. The cost is that its 200×48 rect is dead to the app
        // underneath for the length of a dictation: AppKit gives no way to
        // deliver a click to a window and also pass it on. Small, brief, and
        // deliberately parked below where text fields live.
        panel.ignoresMouseEvents = false
        // Belt and braces alongside .nonactivatingPanel: whatever the user is
        // typing into keeps key status, so the paste still lands there.
        panel.becomesKeyOnlyIfNeeded = true
        // Visible over full-screen apps, and not captured in screen recordings
        // of other apps.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Excluded from screen capture, so a HUD that happens to be up when the
        // screenshot hotkey fires doesn't end up in the meeting notes.
        panel.sharingType = .none

        panel.contentView = FirstMouseHostingView(
            rootView: DictationHUDView(controller: controller)
        )
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

/// Accepts the very first click.
///
/// `NSHostingView` declines first mouse, and this app is never the active one
/// while dictating — that is the whole point of the non-activating panel. So the
/// opening click on the cancel button would be consumed as the click that
/// *would* have activated us, and the user would have to click twice. On a
/// button that exists to be hit once, in a hurry, while looking at another app,
/// that is the difference between an affordance and a decoration.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @MainActor required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used from a nib")
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
            if controller.state.isBusy {
                CancelButton { controller.cancel() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: DictationHUD.size.width, height: DictationHUD.size.height, alignment: .leading)
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
        case .preparing, .transcribing:
            ProgressView().controlSize(.small)
        case .cancelled:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .idle:
            Image(systemName: "mic").foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch controller.state {
        case .listening: "Listening…"
        // Names the model, because the wait is proportional to which one was
        // picked and a silent two-minute "Transcribing…" is what made a working
        // model look broken.
        case .preparing(let what): "\(what)…"
        case .transcribing: "Transcribing…"
        // Said out loud rather than just vanishing. Finishing normally also
        // makes this HUD disappear, so a silent dismissal would leave "I stopped
        // it" and "it finished and typed somewhere I wasn't looking" looking
        // exactly alike — and it is also the only confirmation that the Escape
        // reached us rather than the app underneath.
        case .cancelled: "Cancelled"
        case .failed: "Dictation failed"
        case .idle: "Ready"
        }
    }
}

/// The visible half of the cancel affordance; Escape is the other.
///
/// Always shown rather than revealed on hover: a fallback nobody can find is not
/// a fallback, and the tooltip is where the keyboard gesture gets discovered.
private struct CancelButton: View {
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(isHovering ? Color.primary : Color.secondary)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Cancel dictation (Esc)")
        .accessibilityLabel("Cancel dictation")
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
