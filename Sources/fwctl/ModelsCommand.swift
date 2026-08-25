import ArgumentParser
import Foundation
import FreeWhisperKit

struct Models: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show which speech models are downloaded, and fetch missing ones."
    )

    @Flag(help: "Download anything missing for the default configuration.")
    var download = false

    @Option(help: "Download one model by id.")
    var only: String?

    @Option(help: "Delete one model by id, to reclaim the space.")
    var remove: String?

    func run() async throws {
        if let remove {
            guard let model = ModelCatalog.all.first(where: { $0.id == remove }) else {
                throw ValidationError("Unknown model '\(remove)'.")
            }
            try ModelCatalog.remove(model)
            print("removed \(model.name)")
            return
        }

        if let only {
            guard let model = ModelCatalog.all.first(where: { $0.id == only }) else {
                throw ValidationError(
                    "Unknown model '\(only)'. Options: "
                        + ModelCatalog.all.map(\.id).joined(separator: ", ")
                )
            }
            try await fetch(model)
            return
        }

        if download {
            let missing = ModelCatalog.missingDefaults
            guard !missing.isEmpty else {
                print("all default models are already downloaded")
                return
            }
            print("downloading \(missing.count) model(s), about \(ByteCountFormatter.string(fromByteCount: ModelCatalog.totalBytes(missing), countStyle: .file))\n")
            for model in missing {
                try await fetch(model)
            }
            return
        }

        // Grouped by role, in the same order and under the same names as the
        // settings pane, so the two describe the same thing the same way.
        list("Transcription / voice to text", ModelCatalog.transcribers)
        list("Speaker labels", ModelCatalog.diarizers)
        list("Summaries", ModelCatalog.summarizers)

        let onDisk = ByteCountFormatter.string(fromByteCount: ModelCatalog.bytesOnDisk(), countStyle: .file)
        print("\(onDisk) on disk")

        let missing = ModelCatalog.missingDefaults
        if missing.isEmpty {
            print("defaults ready")
        } else {
            print("defaults missing: \(missing.map(\.name).joined(separator: ", "))")
            print("run `fwctl models --download` to fetch them")
        }
    }

    private func list(_ title: String, _ models: [ModelCatalog.Model]) {
        print("\(title.uppercased())")
        print("  " + "ID".pad(42) + "MODEL".pad(30) + "SIZE".pad(9) + "STATUS")
        for model in models {
            let status = model.isWeightless
                ? "n/a"
                : (ModelCatalog.isDownloaded(model) ? "downloaded" : "missing")
            let size = model.isWeightless ? "—" : model.approximateSize
            print("  " + model.id.pad(42) + model.name.pad(30) + size.pad(9) + status)
        }
        print("")
    }

    private func fetch(_ model: ModelCatalog.Model) async throws {
        print("\(model.name) (\(model.approximateSize))…")
        let started = Date()
        try await ModelCatalog.download(model) { fraction in
            let bars = Int(fraction * 30)
            let bar = String(repeating: "#", count: bars) + String(repeating: ".", count: 30 - bars)
            print("  [\(bar)] \(Int(fraction * 100))%\u{1B}[K\r", terminator: "")
            fflush(stdout)
        }
        print("  done in \(String(format: "%.1f", Date().timeIntervalSince(started)))s\u{1B}[K")
    }
}
