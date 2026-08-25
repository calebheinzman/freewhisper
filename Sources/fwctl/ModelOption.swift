import ArgumentParser
import FreeWhisperKit

/// Resolves `--model`, with `--engine` kept working as a deprecated alias.
///
/// The old flag named an engine, and there was exactly one model per engine, so
/// the mapping is exact and nothing silently changes meaning. Worth keeping:
/// the old spelling is in the README, in shell history, and in whatever anyone
/// has scripted against it.
enum ModelOption {
    static func resolve(
        model: String?,
        engine: String?,
        or fallback: ModelCatalog.Model
    ) throws -> ModelCatalog.Model {
        if let model {
            guard let resolved = ModelCatalog.transcribers.first(where: { $0.id == model }) else {
                throw ValidationError("Unknown model '\(model)'. Options: \(options)")
            }
            return resolved
        }

        if let engine {
            guard let resolved = ModelCatalog.transcriber(migratingEngine: engine) else {
                throw ValidationError(
                    "Unknown engine '\(engine)'. --engine is deprecated; use --model with one of: \(options)"
                )
            }
            return resolved
        }

        return fallback
    }

    static var options: String {
        ModelCatalog.transcribers.map(\.id).joined(separator: ", ")
    }

    static let help = ArgumentHelp(
        "Speech model id. See `fwctl models`.",
        valueName: "id"
    )

    static let deprecatedEngineHelp = ArgumentHelp(
        "Deprecated alias for --model, naming an engine.",
        visibility: .hidden
    )
}
