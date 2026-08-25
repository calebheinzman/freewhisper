import Foundation
import FreeWhisperKit
import Observation

/// Tracks which speech models are on disk and downloads the missing ones.
@Observable
@MainActor
final class ModelSetupModel {
    enum State: Equatable {
        case missing
        case downloading(Double)
        case ready
        case failed(String)
    }

    /// Shared so the menu bar setup panel and the Settings model list show the
    /// same download in flight rather than each starting their own.
    static let shared = ModelSetupModel()

    private(set) var states: [String: State] = [:]
    private(set) var bytesOnDisk: Int64 = 0

    /// Set while the automatic first-run download is running, so the menu bar
    /// can explain why the app isn't ready yet.
    private(set) var isPreparingDefaults = false

    private init() {
        refresh()
    }

    func state(_ model: ModelCatalog.Model) -> State {
        states[model.id] ?? (ModelCatalog.isDownloaded(model) ? .ready : .missing)
    }

    var defaultsAreReady: Bool {
        ModelCatalog.defaults.allSatisfy { state($0) == .ready }
    }

    var missingDefaults: [ModelCatalog.Model] {
        ModelCatalog.defaults.filter { state($0) != .ready }
    }

    /// Combined progress across the first-run download, for a single bar.
    var defaultsProgress: Double {
        let models = ModelCatalog.defaults
        let total = Double(ModelCatalog.totalBytes(models))
        guard total > 0 else { return 1 }

        let done = models.reduce(0.0) { sum, model in
            let fraction: Double = switch state(model) {
            case .ready: 1
            case .downloading(let value): value
            default: 0
            }
            return sum + fraction * Double(model.approximateBytes)
        }
        return done / total
    }

    func refresh() {
        for model in ModelCatalog.all {
            // Don't clobber a download in flight with a disk check that would
            // read as "missing" until the moment it finishes.
            if case .downloading = states[model.id] { continue }
            states[model.id] = ModelCatalog.isDownloaded(model) ? .ready : .missing
        }
        bytesOnDisk = ModelCatalog.bytesOnDisk()
    }

    // MARK: Downloading

    /// Fetches whatever the shipped configuration needs. Called once at launch.
    ///
    /// Sequential rather than concurrent: three parallel downloads share the
    /// same connection and just make each other's progress bars misleading.
    func downloadDefaultsIfNeeded() async {
        guard !isPreparingDefaults else { return }
        refresh()
        guard !defaultsAreReady else { return }

        isPreparingDefaults = true
        Log.transcription.notice("downloading \(self.missingDefaults.count, privacy: .public) default model(s)")

        for model in missingDefaults {
            await download(model)
        }

        isPreparingDefaults = false
        refresh()
    }

    func download(_ model: ModelCatalog.Model) async {
        if case .downloading = state(model) { return }
        states[model.id] = .downloading(0)

        do {
            try await ModelCatalog.download(model) { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = self.states[model.id] else { return }
                    self.states[model.id] = .downloading(fraction)
                }
            }
            states[model.id] = .ready
            bytesOnDisk = ModelCatalog.bytesOnDisk()
            Log.transcription.info("downloaded \(model.id, privacy: .public)")
        } catch {
            states[model.id] = .failed(error.localizedDescription)
            Log.transcription.error("download failed for \(model.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func remove(_ model: ModelCatalog.Model) {
        do {
            try ModelCatalog.remove(model)
            states[model.id] = .missing
            bytesOnDisk = ModelCatalog.bytesOnDisk()
        } catch {
            states[model.id] = .failed(error.localizedDescription)
        }
    }
}
