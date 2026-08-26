import AppKit
import FreeWhisperKit
import Observation
import SwiftUI

/// The "a meeting was detected — record it?" prompt.
///
/// This replaces a macOS notification, which was the wrong medium for a consent
/// question: banners are silently swallowed by a denied permission or a Focus
/// mode, and the one moment we need to ask is the one moment the user is most
/// likely to be in Do Not Disturb — they are in a call. A panel we draw
/// ourselves cannot be suppressed by anything but us.
///
/// It never starts a recording on its own. If the timeout runs out with nobody
/// there, the panel goes away and nothing is recorded: a question nobody
/// answered is not a yes.
@MainActor
final class MeetingPrompt {
    /// One source of truth for the size — it has to agree with the SwiftUI frame
    /// below or the material background and the panel edge stop lining up.
    static let size = NSSize(width: 320, height: 96)

    private var panel: NSPanel?
    private let model = MeetingPromptModel()

    init() {
        // Unplugging the display the panel is on, or rearranging screens, leaves
        // it somewhere arbitrary — possibly half off an edge. Re-place it rather
        // than stranding a consent prompt where it can't be read or clicked.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                self.position(panel)
            }
        }
    }

    /// - Parameter deadline: when to give up and dismiss, or nil to wait for an
    ///   answer however long that takes.
    func show(
        app: String,
        deadline: Date?,
        onRecord: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        model.appName = app
        model.hasAnswered = false
        let seconds = deadline.map { MeetingPromptPolicy.remainingSeconds(until: $0) }
        model.totalSeconds = seconds
        model.secondsRemaining = seconds

        // Answering is latched here rather than at the coordinator: the guards
        // there would catch a double click, but only after the second one had
        // already been drawn as a press.
        model.onRecord = { [weak self] in self?.answer(with: onRecord) }
        model.onDismiss = { [weak self] in self?.answer(with: onDismiss) }

        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Unlike the dictation HUD, which positions only on the way in: this one
        // can be re-shown for a different call on a different display.
        position(panel)
        panel.orderFrontRegardless()
    }

    func update(secondsRemaining: Int) {
        model.secondsRemaining = secondsRemaining
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func answer(with action: () -> Void) {
        guard !model.hasAnswered else { return }
        model.hasAnswered = true
        // Down before the work, so the second half of a double click lands on
        // nothing rather than on a button that is still drawn.
        hide()
        action()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            // .nonactivatingPanel matters more here than anywhere else in the
            // app. The notification this replaces carried `.foreground` on its
            // Record action, so answering it yanked the user out of the call
            // they were joining. Clicking Record here leaves them where they are.
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
        // The buttons need clicks, so the panel cannot wave them through.
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // A "record this call?" panel must never appear in the user's own
        // meeting notes, or in a screen share of the call it is asking about.
        panel.sharingType = .none

        // Built once and kept, unlike ScreenshotHUD which swaps its contentView
        // per message: this one updates once a second, and rebuilding the
        // hosting view at that rate drops hover state and eats a click mid-press.
        panel.contentView = FirstMouseHostingView(
            rootView: MeetingPromptView(model: model)
                // The app is never frontmost while this is up, and SwiftUI draws
                // accented controls grey in an inactive window — the Record
                // button came out looking exactly like Not now, with nothing to
                // mark the one thing the user is meant to reach for. This is a
                // drawing hint only: the panel still never takes focus.
                .environment(\.controlActiveState, .key)
        )
        return panel
    }

    /// Top trailing, just under the menu bar: where the notification this
    /// replaces used to appear, pointing at the menu bar icon the user goes to
    /// next — and clear of the bottom-centre spot the dictation and screenshot
    /// HUDs share, which this panel can occupy for half a minute or longer.
    private func position(_ panel: NSPanel) {
        guard let screen = Self.targetScreen() else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.maxX - size.width - 16,
            y: frame.maxY - size.height - 12
        ))
    }

    /// The screen the pointer is on, not `NSScreen.main`. `main` means "the one
    /// with the key window", and a menu-bar-only app never has one — so it
    /// resolves to the menu bar's screen, which is the wrong display whenever
    /// the call is on the other one.
    private static func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}

@Observable
@MainActor
final class MeetingPromptModel {
    var appName = ""
    /// nil means there is no timeout — the panel waits to be answered.
    var secondsRemaining: Int?
    var totalSeconds: Int?
    var hasAnswered = false

    @ObservationIgnored var onRecord: () -> Void = {}
    @ObservationIgnored var onDismiss: () -> Void = {}
}

private struct MeetingPromptView: View {
    @Bindable var model: MeetingPromptModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "record.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(model.appName) detected")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Record this call?")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if let seconds = model.secondsRemaining {
                    Text("\(seconds)s")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        // Not announced: a counter that re-reads itself every
                        // second makes the panel unusable with VoiceOver, and
                        // the buttons below say everything that matters.
                        .accessibilityHidden(true)
                }
            }

            // No .keyboardShortcut on either button, deliberately. The panel is
            // non-activating and `becomesKeyOnlyIfNeeded`, so it never sees the
            // keystroke — Return goes to whatever app the user is in. Offering a
            // shortcut that silently does nothing is worse than offering none.
            HStack(spacing: 8) {
                // Explicitly tinted rather than left on the accent colour: this
                // panel is never in the active window, and AppKit desaturates
                // accented controls in inactive windows — the one button the
                // user is meant to reach for would have looked exactly like the
                // one they aren't.
                Button("Record") { model.onRecord() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                Button("Not now") { model.onDismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Don't record this call, and don't ask about it again")
                Spacer(minLength: 0)
            }
            .disabled(model.hasAnswered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: MeetingPrompt.size.width, height: MeetingPrompt.size.height, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .bottom) { countdownBar }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(model.appName) detected. Record this call?")
    }

    /// A draining hairline rather than only a number: it makes "this is about to
    /// go away" legible from peripheral vision, which is the only attention this
    /// panel can count on while the user is joining a call.
    @ViewBuilder
    private var countdownBar: some View {
        if let remaining = model.secondsRemaining, let total = model.totalSeconds, total > 0 {
            GeometryReader { geometry in
                Capsule()
                    .fill(Color.accentColor.opacity(0.5))
                    .frame(width: geometry.size.width * CGFloat(remaining) / CGFloat(total), height: 2)
            }
            .frame(height: 2)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
            .animation(.linear(duration: 1), value: model.secondsRemaining)
        }
    }
}
