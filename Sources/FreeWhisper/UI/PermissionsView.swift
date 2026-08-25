import FreeWhisperKit
import SwiftUI

struct PermissionsView: View {
    @Bindable var model: PermissionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Permission.allCases) { permission in
                PermissionRow(
                    permission: permission,
                    state: model.state(permission),
                    action: { Task { await model.request(permission) } }
                )
            }
        }
    }
}

private struct PermissionRow: View {
    let permission: Permission
    let state: PermissionState
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 16)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(permission.title)
                        .font(.system(size: 12, weight: .medium))
                    if !permission.isRequired {
                        Text("optional")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(permission.rationale)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            if !state.isAuthorized {
                Button(buttonTitle, action: action)
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    private var iconName: String {
        switch state {
        case .authorized: "checkmark.circle.fill"
        case .denied: "exclamationmark.triangle.fill"
        case .notDetermined: "circle.dashed"
        }
    }

    private var iconColor: Color {
        switch state {
        case .authorized: .green
        case .denied: permission.isRequired ? .red : .orange
        case .notDetermined: .secondary
        }
    }

    private var buttonTitle: String {
        switch state {
        // Denied permissions can't be re-prompted from the app.
        case .denied: "Open Settings"
        // Probing system audio is what raises the prompt, so name it honestly.
        case .notDetermined where permission == .systemAudio: "Check"
        case .notDetermined: "Grant"
        case .authorized: ""
        }
    }
}
