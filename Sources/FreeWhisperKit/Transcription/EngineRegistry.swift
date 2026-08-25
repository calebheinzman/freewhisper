import Foundation

/// Keeps one instance of each engine alive so models stay loaded.
///
/// Without this, every transcription constructs a fresh engine and reloads its
/// weights — several seconds for Whisper's 626 MB model. Tolerable once per
/// meeting, fatal for dictation, where the entire value is that the text
/// appears the moment you stop talking.
public actor EngineRegistry {
    public static let shared = EngineRegistry()

    /// Keyed by model id rather than by engine: meetings and dictation
    /// routinely run two different Whisper variants, and keying by engine would
    /// make each of them evict the other's weights.
    private var transcribers: [String: any TranscriptionEngine] = [:]
    private var diarizers: [EngineKind: any DiarizationEngine] = [:]

    private init() {}

    public func transcriber(for model: ModelCatalog.Model) -> any TranscriptionEngine {
        if let existing = transcribers[model.id] { return existing }
        let engine: any TranscriptionEngine = switch model.variant {
        case .whisper(let folder): WhisperKitEngine(variant: folder)
        case .parakeet(let version): FluidAudioEngine(version: version)
        case .cloud, .none: CloudTranscriptionEngine()
        }
        transcribers[model.id] = engine
        return engine
    }

    public func diarizer(for model: ModelCatalog.Model) -> any DiarizationEngine {
        // Cloud ASR returns text with no speaker attribution, so the labels
        // have to come from somewhere. SpeakerKit is 11 MB and already a
        // first-run download, which makes it the cheapest way to keep speaker
        // labels working when transcription moves off the machine — which is
        // why `ModelCatalog.diarizer(for:)` pairs cloud with it.
        let kind = ModelCatalog.diarizer(for: model.engine ?? .whisperKit).engine ?? .whisperKit
        if let existing = diarizers[kind] { return existing }
        let engine: any DiarizationEngine = switch kind {
        case .whisperKit, .cloud: SpeakerKitDiarizer()
        case .fluidAudio: FluidAudioDiarizer()
        }
        diarizers[kind] = engine
        return engine
    }

    /// Loads models ahead of time so the first dictation isn't the slow one.
    public func preload(_ model: ModelCatalog.Model) async {
        do {
            try await transcriber(for: model).prepare(progress: nil)
            Log.transcription.info("preloaded \(model.id, privacy: .public)")
        } catch {
            Log.transcription.error("preload failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Drops cached engines, freeing their weights.
    public func unloadAll() {
        transcribers.removeAll()
        diarizers.removeAll()
    }
}
