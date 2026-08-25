import FreeWhisperKit
import SwiftUI

/// First-run model download, shown in the menu bar setup panel.
///
/// The download is automatic, but it is not silent: roughly a gigabyte arriving
/// in the background with no explanation is the kind of thing that makes people
/// distrust an app that also records their conversations.
struct ModelSetupRow: View {
    @Bindable var models: ModelSetupModel

    var body: some View {
        if !models.defaultsAreReady {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .foregroundStyle(iconColor)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: 12, weight: .medium))
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 4)

                    if !models.isPreparingDefaults {
                        Button(hasFailure ? "Retry" : "Download") {
                            Task { await models.downloadDefaultsIfNeeded() }
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                    }
                }

                if models.isPreparingDefaults {
                    ProgressView(value: models.defaultsProgress)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
            }
        }
    }

    private var hasFailure: Bool {
        ModelCatalog.defaults.contains {
            if case .failed = models.state($0) { return true }
            return false
        }
    }

    private var icon: String {
        if models.isPreparingDefaults { return "arrow.down.circle" }
        return hasFailure ? "exclamationmark.triangle.fill" : "square.and.arrow.down"
    }

    private var iconColor: Color {
        if models.isPreparingDefaults { return .accentColor }
        return hasFailure ? .orange : .secondary
    }

    private var title: String {
        models.isPreparingDefaults ? "Downloading speech models…" : "Speech models"
    }

    private var detail: String {
        if let failure = firstFailure {
            return failure
        }
        if models.isPreparingDefaults {
            let name = models.missingDefaults.first?.name ?? ""
            return "\(name) — \(Int(models.defaultsProgress * 100))%"
        }
        let size = ByteCountFormatter.string(
            fromByteCount: ModelCatalog.totalBytes(models.missingDefaults),
            countStyle: .file
        )
        return "\(size) needed before FreeWhisper can transcribe anything."
    }

    private var firstFailure: String? {
        for model in ModelCatalog.defaults {
            if case .failed(let message) = models.state(model) {
                return "\(model.name): \(message)"
            }
        }
        return nil
    }
}
