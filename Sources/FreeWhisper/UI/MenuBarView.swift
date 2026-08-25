import AppKit
import FreeWhisperKit
import SwiftUI

struct MenuBarView: View {
    @Bindable var coordinator: AppCoordinator
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    /// Drives the elapsed-time label; the recording itself is timed from the
    /// session's own start date, not from this.
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if coordinator.phase.isRecording {
                LevelMeters(
                    micLevel: coordinator.status.micLevel,
                    systemLevel: coordinator.status.systemLevel,
                    micActive: coordinator.status.micActive,
                    systemActive: coordinator.status.systemActive
                )
                .padding(.top, 10)

                if let warning = coordinator.status.warning {
                    Banner(text: warning, tone: .warning).padding(.top, 8)
                }
            }

            if let error = coordinator.lastError {
                Banner(text: error, tone: .error).padding(.top, 8)
            }

            Divider().padding(.vertical, 8)

            if !coordinator.permissions.isReadyToRecord || !coordinator.models.defaultsAreReady {
                setupSection
                Divider().padding(.vertical, 8)
            }

            controls

            if !coordinator.meetings.isEmpty {
                Divider().padding(.vertical, 8)
                recentSection
            }

            Divider().padding(.vertical, 8)

            footer
        }
        .padding(12)
        .frame(width: 320)
        .task { await coordinator.onAppear() }
        .onReceive(tick) { now = $0 }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 8) {
            StatusDot(phase: coordinator.phase)
            VStack(alignment: .leading, spacing: 1) {
                Text(statusTitle)
                    .font(.system(size: 13, weight: .semibold))
                if let detail = statusDetail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer()
        }
    }

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Setup")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if !coordinator.permissions.isReadyToRecord {
                PermissionsView(model: coordinator.permissions)
            }
            ModelSetupRow(models: coordinator.models)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                coordinator.toggleRecording()
            } label: {
                Label(
                    coordinator.phase.isActive ? "Stop Recording" : "Start Recording",
                    systemImage: coordinator.phase.isActive ? "stop.circle.fill" : "record.circle"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!coordinator.permissions.isReadyToRecord && !coordinator.phase.isActive)

            Toggle("Auto-detect meetings", isOn: $coordinator.autoDetectEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 12))

            dictationStatus
        }
    }

    /// Always says how to start dictation, or why you can't. An earlier version
    /// could end up with no trigger bound at all and showed nothing anywhere,
    /// which is why this line is not conditional on something being wrong.
    private var dictationStatus: some View {
        HStack(spacing: 5) {
            Image(systemName: coordinator.dictation.hasNoTrigger ? "exclamationmark.triangle.fill" : "mic")
                .font(.system(size: 10))
                .foregroundStyle(coordinator.dictation.hasNoTrigger ? .orange : .secondary)
            Text(dictationTriggerText)
                .font(.system(size: 11))
                .foregroundStyle(coordinator.dictation.hasNoTrigger ? .orange : .secondary)
        }
    }

    private var dictationTriggerText: String {
        if coordinator.dictation.chordIsActive { return "Dictate: hold ⌘⎋" }
        if coordinator.dictation.customShortcut != nil { return "Dictate: your custom shortcut" }
        if coordinator.dictation.chordEnabled { return "Dictation needs Accessibility" }
        return "Dictation has no shortcut"
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(coordinator.meetings.prefix(4)) { meeting in
                Button {
                    MeetingsModel.shared.select(id: meeting.id)
                    openMeetingsWindow()
                } label: {
                    HStack(spacing: 6) {
                        Text(meeting.displayTitle)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer()
                        Text(Self.durationText(meeting.duration))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Meetings…") { openMeetingsWindow() }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
            Spacer()
            Button("Settings…") { openSettingsWindow() }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
        }
    }

    // MARK: Status text

    private var statusTitle: String {
        switch coordinator.phase {
        case .idle:
            (coordinator.permissions.isReadyToRecord && coordinator.models.defaultsAreReady)
                ? (coordinator.autoDetectEnabled ? "Listening for meetings" : "Idle")
                : "Setup needed"
        case .meetingDetected(let app, _):
            "\(app) detected"
        case .starting:
            "Starting…"
        case .recording:
            "Recording"
        case .processing(let step):
            step
        }
    }

    private var statusDetail: String? {
        switch coordinator.phase {
        case .idle:
            let missing = coordinator.permissions.blockingPermissions
            if !missing.isEmpty {
                return "Needs \(missing.map(\.title).joined(separator: " and "))"
            }
            if coordinator.models.isPreparingDefaults {
                return "Downloading speech models…"
            }
            if !coordinator.models.defaultsAreReady {
                return "Speech models not downloaded"
            }
            return coordinator.autoDetectEnabled ? nil : "Auto-detect is off"
        case .meetingDetected(_, let seconds):
            return "Recording starts in \(seconds)s"
        case .starting:
            // The tap call blocks behind the TCC dialog on a first run, and a
            // bare spinner with no explanation reads as a hang.
            return "Waiting for audio permission…"
        case .recording(let startedAt):
            return Self.durationText(now.timeIntervalSince(startedAt))
        case .processing:
            return nil
        }
    }

    private func openMeetingsWindow() {
        openWindow(id: WindowID.meetings)
        // A menu bar app is an accessory by default, so an opened window would
        // otherwise appear behind whatever the user was in.
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Opens Settings, and brings it forward if it is already open.
    ///
    /// `openSettings()` alone orders the window front within our own window
    /// list, but an accessory app never becomes active on its own, so a window
    /// that already existed stayed behind whatever the user was looking at. The
    /// first click worked — creating the window happens to bring the app
    /// forward — and every click after it did nothing visible. Since the panel
    /// dismisses on any click regardless, that was indistinguishable from the
    /// button being dead.
    private func openSettingsWindow() {
        let wasOpen = Self.settingsWindow()?.isVisible ?? false
        openSettings()
        NSApplication.shared.activate(ignoringOtherApps: true)

        // Activation alone does not pull a window across Spaces, and does not
        // make it key. Both need the window itself, which SwiftUI does not hand
        // out — hence the lookup below. Deferred a turn so the window exists on
        // the first open, when `openSettings()` has only just created it.
        DispatchQueue.main.async {
            guard let window = Self.settingsWindow() else { return }
            window.collectionBehavior.insert(.moveToActiveSpace)
            // Only centre when it wasn't already on screen. Re-centring a window
            // the user has deliberately placed is its own small annoyance, and
            // "bring it forward" should not move it.
            if !wasOpen { window.center() }
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// SwiftUI gives the Settings scene no identifier we can ask for, so this
    /// matches on the internal one it assigns. That is not API and may change,
    /// which is why every caller treats a miss as fine: the `activate` call above
    /// is what does the load-bearing work, and this only adds Space-switching and
    /// key focus on top.
    private static func settingsWindow() -> NSWindow? {
        NSApp.windows.first { window in
            guard let id = window.identifier?.rawValue else { return false }
            return id.contains("Settings") || id.contains("settings")
        }
    }

    private static func durationText(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Coloured state indicator. Recording is unmissably red on purpose.
private struct StatusDot: View {
    let phase: AppPhase

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private var color: Color {
        switch phase {
        case .idle: .secondary
        case .meetingDetected, .starting: .orange
        case .recording: .red
        case .processing: .blue
        }
    }
}

private struct Banner: View {
    enum Tone { case warning, error }

    let text: String
    let tone: Tone

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: tone == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tone == .error ? Color.red : Color.orange)
        .padding(6)
        .background((tone == .error ? Color.red : Color.orange).opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
    }
}
