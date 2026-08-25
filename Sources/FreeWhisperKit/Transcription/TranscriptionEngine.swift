import Foundation

/// Which implementation runs a speech model.
///
/// Deliberately *not* what the user picks. These are the names of the SDKs we
/// depend on, and "FluidAudio" tells someone nothing about which of the things
/// the app does with speech it affects. The user picks a
/// ``ModelCatalog/Model``; the engine is derived from it.
public enum EngineKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Whisper via CoreML, plus pyannote diarization (argmax-oss-swift).
    case whisperKit
    /// Parakeet TDT plus pyannote diarization (FluidAudio).
    case fluidAudio
    /// Any OpenAI-compatible `/v1/audio/transcriptions` endpoint, using the
    /// user's own key. Speaker labels still come from the local diarizer.
    case cloud

    public var id: String { rawValue }

    /// True for engines that run entirely on this Mac.
    public var isOnDevice: Bool { self != .cloud }
}

/// Which weights an engine should load.
///
/// The engine is derivable from the case, so it isn't stored alongside — two
/// fields that can disagree about the same fact is one field too many.
public enum SpeechVariant: Sendable, Hashable {
    /// The exact folder name in `argmaxinc/whisperkit-coreml`.
    ///
    /// Exact, because `WhisperKit.download(variant:)` treats this as the glob
    /// `*<variant>/*` and throws when more than one folder matches. A short
    /// name like `"tiny"` is ambiguous; the folder name never is.
    case whisper(String)
    case parakeet(ParakeetVersion)
    /// No weights at all — an OpenAI-compatible endpoint.
    case cloud

    public var engine: EngineKind {
        switch self {
        case .whisper: .whisperKit
        case .parakeet: .fluidAudio
        case .cloud: .cloud
        }
    }
}

/// Mirrors FluidAudio's `AsrModelVersion`, which is `Sendable` but neither
/// `Hashable` nor `Codable`, and which we would rather not have leaking through
/// our own API surface.
public enum ParakeetVersion: String, Sendable, Hashable {
    case v3
    case v2
    case tdtCtc110m
}

/// Progress while a model downloads or audio is processed, for the UI.
public enum EngineProgress: Sendable, Equatable {
    case downloadingModel(name: String, fraction: Double?)
    case loadingModel(name: String)
    case transcribing(fraction: Double?)
    case diarizing(fraction: Double?)
}

public typealias ProgressHandler = @Sendable (EngineProgress) -> Void

/// Turns an audio file into timed text.
public protocol TranscriptionEngine: Sendable {
    var kind: EngineKind { get }

    /// Downloads and loads models if needed. Safe to call repeatedly.
    func prepare(progress: ProgressHandler?) async throws

    /// `url` must be a 16 kHz mono WAV — what `ResamplingRecorder` writes.
    func transcribe(url: URL, progress: ProgressHandler?) async throws -> [RawSegment]
}

/// Splits an audio file into per-speaker turns.
public protocol DiarizationEngine: Sendable {
    var kind: EngineKind { get }

    func prepare(progress: ProgressHandler?) async throws

    func diarize(url: URL, progress: ProgressHandler?) async throws -> [SpeakerTurn]
}

public enum TranscriptionError: LocalizedError {
    case audioFileMissing(URL)
    case audioFileEmpty(URL)
    case modelUnavailable(String)
    case engineFailed(engine: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .audioFileMissing(let url):
            "Audio file is missing: \(url.lastPathComponent)"
        case .audioFileEmpty(let url):
            "Audio file has no samples: \(url.lastPathComponent)"
        case .modelUnavailable(let name):
            "Model '\(name)' could not be loaded. Check your connection for the first download."
        case .engineFailed(let engine, let reason):
            "\(engine) failed: \(reason)"
        }
    }
}
