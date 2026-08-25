import FreeWhisperKit
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        TabView {
            GeneralSettings(coordinator: coordinator)
                .tabItem { Label("General", systemImage: "gearshape") }
            DetectionSettingsView()
                .tabItem { Label("Detection", systemImage: "sensor") }
            DictationSettings(controller: coordinator.dictation)
                .tabItem { Label("Dictation", systemImage: "mic") }
            ScreenshotSettings(controller: coordinator.screenshots)
                .tabItem { Label("Screenshots", systemImage: "photo") }
            IntelligenceSettingsView()
                .tabItem { Label("Intelligence", systemImage: "sparkles") }
        }
        .frame(width: 560, height: 560)
    }
}

private struct GeneralSettings: View {
    @Bindable var coordinator: AppCoordinator
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Section("Permissions") {
                PermissionsView(model: coordinator.permissions)
            }
            Section {
                Toggle("Auto-detect meetings", isOn: $coordinator.autoDetectEnabled)
            } footer: {
                Text("Watches which apps are using your microphone. Recording never starts without asking first.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in
                        if !LaunchAtLogin.set(value) {
                            // macOS can park the request pending approval; put
                            // the toggle back rather than lying about the state.
                            launchAtLogin = LaunchAtLogin.isEnabled
                            if LaunchAtLogin.needsApproval {
                                LaunchAtLogin.openLoginItemsSettings()
                            }
                        }
                    }
            } footer: {
                Text("A meeting detector that only runs when you remember to start it isn't much of a detector.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            await coordinator.refreshPermissions()
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }
}

private struct DetectionSettingsView: View {
    @AppStorage(SettingsKeys.autoStartCountdown) private var countdown = 10

    var body: some View {
        Form {
            Section {
                Picker("When a meeting is detected", selection: $countdown) {
                    Text("Just notify me").tag(0)
                    Text("Start recording after 5s").tag(5)
                    Text("Start recording after 10s").tag(10)
                    Text("Start recording after 30s").tag(30)
                }
            } footer: {
                Text(countdown == 0
                    ? "You'll get a notification with a Record button. Nothing is recorded until you click it."
                    : "You'll get a notification with a countdown. Click \"Not now\" to cancel, and this call won't be asked about again.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(KnownApps.defaults) { app in
                    LabeledContent(app.displayName) {
                        Text(app.kind.displayName)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Watched apps")
            } footer: {
                Text("A call is detected when one of these apps starts using your microphone. Audio playing on its own — a notification chime, music — never counts.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}


private struct DictationSettings: View {
    @Bindable var controller: DictationController
    @State private var mode: DictationMode = .pushToTalk
    @State private var chordEnabled = true

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $chordEnabled) {
                    HStack(spacing: 6) {
                        Text("Hold ⌘⎋ to dictate")
                        if chordEnabled && !controller.chordIsActive {
                            Text("needs Accessibility")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                        }
                    }
                }
            } header: {
                Text("Voice to text")
            } footer: {
                Text("Hold Command and Escape, speak, then let go — the text is typed into whatever app you're in. Keeping either key down keeps it recording, so you don't have to hold the pair perfectly still. The model it uses is set in Settings → Intelligence, and the recording is deleted straight after.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Section {
                KeyboardShortcuts.Recorder("Extra shortcut", name: .dictate)
                Picker("Behaviour", selection: $mode) {
                    ForEach(DictationMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .disabled(controller.customShortcut == nil)
            } header: {
                Text("Extra shortcut")
            } footer: {
                Text(controller.customShortcut == nil
                    ? "Optional. ⌘⎋ works without one; add a shortcut here if you'd rather use something else, or want a press-to-start-press-to-stop option for longer dictation."
                    : "Applies to the shortcut above. ⌘⎋ is always hold-to-talk.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if controller.hasNoTrigger {
                Section {
                    Label(
                        "Dictation has no way to be triggered. Turn on ⌘⎋ above, grant Accessibility, or set a shortcut.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                }
            }

            Section {
                LabeledContent("Accessibility") {
                    HStack(spacing: 6) {
                        Image(systemName: isTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(isTrusted ? .green : .orange)
                        if !isTrusted {
                            Button("Grant") {
                                Permissions.requestAccessibility()
                                Permissions.openSettings(for: .accessibility)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            } footer: {
                Text("Required both to detect ⌘⎋ and to type the result into other apps.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Check it works") {
                    Button(controller.state == .idle ? "Test dictation" : "Listening…") {
                        controller.runSelfTest()
                    }
                    .disabled(controller.state != .idle)
                }
            } footer: {
                Text("Records for four seconds and types the result, skipping the hotkey entirely. If this works but ⌘⎋ doesn't, the problem is the trigger and not the microphone or the model.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            mode = controller.mode
            chordEnabled = controller.chordEnabled
        }
        .onChange(of: mode) { _, newValue in controller.mode = newValue }
        .onChange(of: chordEnabled) { _, newValue in controller.chordEnabled = newValue }
    }

    private var isTrusted: Bool {
        Permissions.accessibilityState().isAuthorized
    }
}

private struct ScreenshotSettings: View {
    let controller: ScreenshotController

    @AppStorage(SettingsKeys.screenshotAllDisplays) private var allDisplays = true
    /// Re-read on appear rather than observed: the grant happens in System
    /// Settings, out of the app's sight.
    @State private var permission = Permissions.screenRecordingState()

    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Shortcut", name: .meetingScreenshot)
                Picker("Capture", selection: $allDisplays) {
                    Text("All displays").tag(true)
                    Text("Display with the pointer").tag(false)
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Screenshot")
            } footer: {
                Text("Captures only while a meeting is recording, and files the image into that meeting at the second it was taken. Press it outside a recording and nothing happens.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Screen Recording") {
                    HStack(spacing: 6) {
                        Image(systemName: permission.isAuthorized ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(permission.isAuthorized ? .green : .orange)
                        if !permission.isAuthorized {
                            Button("Grant") {
                                Permissions.requestScreenRecording()
                                permission = Permissions.screenRecordingState()
                                if !permission.isAuthorized {
                                    Permissions.openSettings(for: .screenRecording)
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            } footer: {
                // Worth stating plainly: without it, captures come back as
                // black frames and the feature looks broken rather than
                // half-configured.
                Text("macOS only applies this grant to a fresh launch — quit and reopen FreeWhisper after allowing it.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if let result = controller.lastResult {
                Section("Last screenshot") {
                    Text(result)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { permission = Permissions.screenRecordingState() }
    }
}
