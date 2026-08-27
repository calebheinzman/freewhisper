import FluidAudio
import Foundation
import HuggingFace
import SpeakerKit
import WhisperKit

/// Which model bundles exist on disk, and how to fetch the missing ones.
///
/// Both SDKs download lazily on first inference, which is the wrong moment: the
/// first inference is right after the user's first real meeting, and a silent
/// 600 MB download that fails offline loses them the transcript of a call they
/// have already had. Setup should ask first.
///
/// The same catalog covers the summarization models, so "which weights do I
/// have and what are they costing me in disk" is one question with one answer
/// rather than one per subsystem.
public enum ModelCatalog {
    /// What a model is for.
    ///
    /// These are the three roles the settings pane names, plus diarization,
    /// which the user never picks: it follows whichever engine is transcribing.
    public enum Group: Sendable, Hashable {
        case transcription(SpeechVariant)
        case diarization(engine: EngineKind)
        case summarization

        public var isDiarizer: Bool {
            if case .diarization = self { return true }
            return false
        }

        public var engine: EngineKind? {
            switch self {
            case .transcription(let variant): variant.engine
            case .diarization(let engine): engine
            case .summarization: nil
            }
        }
    }

    public struct Model: Sendable, Identifiable, Equatable {
        /// Stable catalog identifier, persisted in UserDefaults as the user's
        /// choice. Deliberately short and ours rather than the upstream folder
        /// or repo name — a rename upstream must not silently deselect a
        /// model. (Summarizers are the exception: there the id *is* the
        /// HuggingFace repo id, because that is what makes them addressable.)
        public let id: String
        public let name: String
        /// The tradeoff this model makes, in one line, shown where it's chosen.
        public let detail: String
        /// Approximate download size, for telling the user what they're in for.
        public let approximateBytes: Int64
        public let group: Group

        public var engine: EngineKind? { group.engine }
        public var isDiarizer: Bool { group.isDiarizer }
        public var isSummarizer: Bool { group == .summarization }

        public var variant: SpeechVariant? {
            if case .transcription(let variant) = group { return variant }
            return nil
        }

        /// True for models with nothing to fetch. Only the cloud entry, which
        /// is a real choice in the same list but not a real download.
        public var isWeightless: Bool { variant == .cloud }

        public var approximateSize: String {
            ByteCountFormatter.string(fromByteCount: approximateBytes, countStyle: .file)
        }
    }

    // MARK: Speech to text

    /// Sizes below are measured byte counts of the downloaded directory.
    ///
    /// Measured rather than inferred because both available shortcuts are
    /// wrong: the `_626MB` in a WhisperKit folder name is decimal MB, so
    /// reading it as MiB overstates by 5%, and a "110M parameter" model lands
    /// as 227 MB on disk because FluidAudio fetches 17 files for it. Both of
    /// those were live errors in this file before they were measured.

    public static let whisperTurbo = Model(
        id: "whisper-large-v3-turbo",
        name: "Whisper large-v3 turbo",
        detail: "The balanced default. 90+ languages, strongest on accents.",
        approximateBytes: 626_718_238,
        group: .transcription(.whisper("openai_whisper-large-v3-v20240930_626MB"))
    )

    public static let parakeetV3 = Model(
        id: "parakeet-v3",
        name: "Parakeet TDT 0.6b v3",
        detail: "Around 8× faster than Whisper. 25 European languages.",
        approximateBytes: 483_257_242,
        group: .transcription(.parakeet(.v3))
    )

    public static let whisperLargeV3 = Model(
        id: "whisper-large-v3",
        name: "Whisper large-v3",
        detail: "The most accurate, and the slowest. 90+ languages.",
        // From the folder name, the only one here not measured directly. The
        // name proved accurate to 0.1% for the turbo variant above.
        approximateBytes: 947_000_000,
        group: .transcription(.whisper("openai_whisper-large-v3_947MB"))
    )

    public static let distilWhisper = Model(
        id: "distil-whisper-large-v3",
        name: "Distil-Whisper large-v3 turbo",
        detail: "English only, roughly twice the speed of Whisper turbo.",
        approximateBytes: 607_114_331,
        group: .transcription(.whisper("distil-whisper_distil-large-v3_turbo_600MB"))
    )

    public static let parakeet110M = Model(
        id: "parakeet-110m",
        name: "Parakeet TDT-CTC 110M",
        detail: "The smallest and fastest, for instant dictation. English only.",
        approximateBytes: 227_468_698,
        group: .transcription(.parakeet(.tdtCtc110m))
    )

    /// A real choice in the same list, with nothing to download. Listing it
    /// beside the local models is the point: cloud transcription already
    /// worked, but behind a separate engine picker nobody thought to open.
    public static let cloudTranscription = Model(
        id: "cloud",
        name: "Cloud API (your own key)",
        detail: "Nothing to download, and you pay per minute. Recordings are uploaded.",
        approximateBytes: 0,
        group: .transcription(.cloud)
    )

    /// Ordered as offered: the two defaults first, then the rest by size.
    public static let transcribers: [Model] = [
        whisperTurbo,
        parakeetV3,
        whisperLargeV3,
        distilWhisper,
        parakeet110M,
        cloudTranscription,
    ]

    // MARK: Speaker labels

    public static let speakerKitDiarizer = Model(
        id: "speakerkit-diarizer",
        name: "Pyannote (SpeakerKit)",
        detail: "Works out who said what. Used with Whisper and with cloud transcription.",
        approximateBytes: 11 * 1_024 * 1_024,
        group: .diarization(engine: .whisperKit)
    )

    /// The offline community-1 pipeline, which is four models rather than the
    /// streaming pipeline's two — segmentation, filterbank, embedding and the
    /// PLDA transform that VBx clustering needs.
    public static let fluidAudioDiarizer = Model(
        id: "fluidaudio-diarizer",
        name: "Pyannote community-1 (FluidAudio)",
        detail: "Works out who said what. Used with Parakeet.",
        approximateBytes: 21 * 1_024 * 1_024,
        group: .diarization(engine: .fluidAudio)
    )

    public static let diarizers: [Model] = [speakerKitDiarizer, fluidAudioDiarizer]

    /// Which diarizer pairs with an engine.
    ///
    /// Cloud borrows SpeakerKit — cloud ASR returns text with no speaker
    /// attribution, so the labels have to be worked out here. Keeping this in
    /// one place is what stops the settings pane and ``EngineRegistry`` from
    /// disagreeing about which model is actually in use.
    public static func diarizer(for engine: EngineKind) -> Model {
        switch engine {
        case .whisperKit, .cloud: speakerKitDiarizer
        case .fluidAudio: fluidAudioDiarizer
        }
    }

    // MARK: Summarization

    /// A deliberately short list of 4-bit MLX conversions.
    ///
    /// The point of shipping these is that summarization works without the user
    /// first installing an inference server, and a wall of near-identical
    /// quantizations would undo that. Three sizes: one that is good, one that
    /// is smaller, one that fits on an 8 GB machine. Anything more specific is
    /// what the Ollama and custom-endpoint options are for.
    public static let qwen3_4B = Model(
        id: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
        name: "Qwen3 4B Instruct",
        detail: "The built-in default. Best quality of the three.",
        approximateBytes: 2_280_000_000,
        group: .summarization
    )

    public static let llama3_2_3B = Model(
        id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
        name: "Llama 3.2 3B Instruct",
        detail: "Smaller and quicker, at some cost in structure.",
        approximateBytes: 1_820_000_000,
        group: .summarization
    )

    public static let qwen3_1_7B = Model(
        id: "mlx-community/Qwen3-1.7B-4bit",
        name: "Qwen3 1.7B",
        detail: "Fits comfortably on an 8 GB Mac.",
        approximateBytes: 980_000_000,
        group: .summarization
    )

    /// What ``LLMProvider/onDevice`` points at out of the box.
    public static let defaultSummarizer = qwen3_4B

    public static let summarizers: [Model] = [qwen3_4B, llama3_2_3B, qwen3_1_7B]

    public static let all: [Model] = transcribers + diarizers + summarizers

    public static func model(id: String) -> Model? {
        all.first { $0.id == id }
    }

    // MARK: Selection

    /// Meetings can afford to wait for accuracy.
    public static let defaultTranscriber = whisperTurbo
    /// Dictation cannot: the whole value is the text landing the moment you
    /// stop talking, which is why the two roles ship with different defaults.
    public static let defaultDictationTranscriber = parakeetV3

    /// Resolves a persisted choice, falling back rather than failing.
    ///
    /// A stored id that no longer exists — a model we retired, or a profile
    /// written by a newer build — must leave the user with something that
    /// works, not with nothing selected.
    public static func transcriber(id: String?, or fallback: Model) -> Model {
        guard let id, let model = transcribers.first(where: { $0.id == id }) else { return fallback }
        return model
    }

    /// Maps the ``EngineKind`` raw values older builds persisted onto the model
    /// that replaced them.
    ///
    /// Before models were selectable there was one per engine, so the mapping
    /// is exact and nobody's choice changes under them on upgrade.
    public static func transcriber(migratingEngine raw: String) -> Model? {
        switch raw {
        case EngineKind.whisperKit.rawValue: whisperTurbo
        case EngineKind.fluidAudio.rawValue: parakeetV3
        case EngineKind.cloud.rawValue: cloudTranscription
        default: nil
        }
    }

    /// What a first run needs before the app can do anything useful.
    ///
    /// The two shipped defaults and the diarizer that pairs with the meeting
    /// one. Everything else is opt-in: FluidAudio's diarizer is only reached if
    /// meetings switch to Parakeet, and the summarizers stay out because
    /// summarization ships off — 2 GB pulled on first launch for a feature
    /// nobody has turned on is indefensible.
    public static var defaults: [Model] {
        [defaultTranscriber, diarizer(for: defaultTranscriber.engine ?? .whisperKit), defaultDictationTranscriber]
    }

    public static var defaultsAreReady: Bool {
        defaults.allSatisfy(isDownloaded)
    }

    /// Default models that aren't present yet.
    public static var missingDefaults: [Model] {
        defaults.filter { !isDownloaded($0) }
    }

    // MARK: Presence

    public static func isDownloaded(_ model: Model) -> Bool {
        switch model.group {
        // Nothing to fetch: the weights are the provider's problem. Reporting
        // it as present is what keeps it a plain row in the same list.
        case .transcription(.cloud):
            return true
        case .transcription(.whisper(let folder)):
            return directoryHasCompiledModels(whisperDirectory(folder))
        case .transcription(.parakeet(let version)):
            return directoryHasCompiledModels(AsrModels.defaultCacheDirectory(for: version.asrVersion))
        case .diarization(engine: .whisperKit), .diarization(engine: .cloud):
            return directoryHasCompiledModels(speakerKitDirectory())
        case .diarization(engine: .fluidAudio):
            return hasOfflineDiarizerModels()
        case .summarization:
            return summarizerSnapshot(model) != nil
        }
    }

    public static func totalBytes(_ models: [Model]) -> Int64 {
        models.reduce(0) { $0 + $1.approximateBytes }
    }

    // MARK: Downloading

    /// Fetches a model, reporting 0...1 progress where the SDK provides it.
    public static func download(
        _ model: Model,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        switch model.group {
        case .transcription(.cloud):
            progress?(1)

        case .transcription(.whisper(let folder)):
            _ = try await WhisperKit.download(
                variant: folder,
                downloadBase: ModelStorage.downloadBase(),
                progressCallback: { progress?($0.fractionCompleted) }
            )

        case .transcription(.parakeet(let version)):
            // `download` rather than `downloadAndLoad`: the caller wants the
            // weights on disk, and loading them into a manager we then throw
            // away costs seconds and a few hundred MB of memory for nothing.
            _ = try await AsrModels.download(
                version: version.asrVersion,
                progressHandler: { progress?($0.fractionCompleted) }
            )

        case .diarization(engine: .whisperKit), .diarization(engine: .cloud):
            // SpeakerKit reports no download progress, so this is a long
            // indeterminate wait. It is only ~11 MB, so that is tolerable.
            _ = try await SpeakerKit(PyannoteConfig(
                downloadBase: ModelStorage.downloadBase().path,
                download: true,
                load: false
            ))
            progress?(1)

        case .diarization(engine: .fluidAudio):
            // `load` rather than a bare download: it is the only public entry
            // point that fetches the offline variant, and it compiles the
            // models too, which is work the first meeting would otherwise pay.
            _ = try await OfflineDiarizerModels.load(
                progressHandler: { progress?($0.fractionCompleted) }
            )
            progress?(1)

        case .summarization:
            try await downloadSummarizer(model, progress: progress)
        }
    }

    /// Pulls an MLX conversion into a HuggingFace cache of our own.
    ///
    /// Deliberately not the shared `~/.cache/huggingface` tree `HubClient`
    /// would use by default: that cache belongs to whatever Python tooling the
    /// user already has, and quietly adding gigabytes to it — then deleting
    /// from it when they press Remove in our Settings pane — is not our call to
    /// make. Pointing the cache at our own directory rather than copying out of
    /// the shared one also means one copy on disk instead of two.
    private static func downloadSummarizer(
        _ model: Model,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        guard let repo = Repo.ID(rawValue: model.id) else {
            throw TranscriptionError.modelUnavailable(model.name)
        }

        do {
            _ = try await HubClient(cache: summarizerCache).downloadSnapshot(
                of: repo,
                matching: summarizerFilePatterns,
                progressHandler: { fraction in progress?(fraction.fractionCompleted) }
            )
        } catch {
            // A partial download leaves blobs behind that cost the user disk
            // and load into nothing. Take it back out.
            try? FileManager.default.removeItem(at: summarizerRepoDirectory(model))
            throw error
        }
        progress?(1)
    }

    /// What MLX's loader needs: weights, the configs beside them, and the chat
    /// template. Matches `modelDownloadPatterns` in MLXLMCommon, so nothing is
    /// missing at load time and nothing extra comes down.
    static let summarizerFilePatterns = ["*.safetensors", "*.json", "*.jinja"]

    /// Deletes a model's weights so the user can reclaim the space.
    ///
    /// Removing a model that is still selected is allowed — it will simply be
    /// re-downloaded on next use. The UI warns rather than forbids.
    public static func remove(_ model: Model) throws {
        guard let directory = directory(for: model) else { return }
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
        Log.transcription.notice("removed model \(model.id, privacy: .public)")
    }

    static func directory(for model: Model) -> URL? {
        switch model.group {
        case .transcription(.cloud):
            return nil
        case .transcription(.whisper(let folder)):
            return whisperDirectory(folder)
        case .transcription(.parakeet(let version)):
            return AsrModels.defaultCacheDirectory(for: version.asrVersion)
        case .diarization(engine: .whisperKit), .diarization(engine: .cloud):
            return speakerKitDirectory()
        case .diarization(engine: .fluidAudio):
            return offlineDiarizerDirectory()
        case .summarization:
            return summarizerRepoDirectory(model)
        }
    }

    /// Where FluidAudio caches the diarizer repo.
    ///
    /// `DiarizerModels.defaultModelsDirectory()` already resolves to it, and
    /// the offline variant lands in the same folder — different files, same
    /// repo — so this is a name for what that path means rather than a
    /// different path.
    private static func offlineDiarizerDirectory() -> URL {
        DiarizerModels.defaultModelsDirectory()
    }

    /// Check the offline pipeline's four models by name.
    ///
    /// The generic "is there any `.mlmodelc` in here" test is wrong for this
    /// one: anybody who ran an older build has the streaming pipeline's two
    /// models sitting in this very folder, and that would report the offline
    /// models as present, skip the download, and fail in the middle of the
    /// first meeting instead of during setup.
    private static func hasOfflineDiarizerModels() -> Bool {
        let directory = offlineDiarizerDirectory()
        return ModelNames.OfflineDiarizer.requiredModels.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    // MARK: Locations

    /// Where each SDK caches its weights, for the "reveal in Finder" affordance
    /// and so the user can reclaim the space themselves.
    ///
    /// Built from the catalog rather than listed by hand: every Parakeet
    /// version caches under its own repo directory, so a hardcoded list would
    /// quietly stop counting a model the moment one was added. Deduplicated by
    /// path because ``bytesOnDisk`` sums these, and the Whisper root covers all
    /// of its variants at once.
    public static func cacheDirectories() -> [URL] {
        var seen = Set<String>()
        let roots = (transcribers + diarizers).compactMap { model -> URL? in
            if case .transcription(.whisper) = model.group { return whisperKitRoot() }
            return directory(for: model)
        }
        return (roots + [summarizerRoot()])
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Root of the MLX weights we manage ourselves. Sits beside the meeting
    /// store rather than in Documents, because it is app data the user never
    /// opens directly.
    static func summarizerRoot() -> URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("FreeWhisper/Models", isDirectory: true)
    }

    static var summarizerCache: HubCache {
        HubCache(location: .fixed(directory: summarizerRoot()))
    }

    /// Everything belonging to one repo — blobs, refs and snapshots. This is
    /// the unit the user removes.
    static func summarizerRepoDirectory(_ model: Model) -> URL {
        guard let repo = Repo.ID(rawValue: model.id) else {
            return summarizerRoot().appendingPathComponent(model.id, isDirectory: true)
        }
        return summarizerCache.repoDirectory(repo: repo, kind: .model)
    }

    /// The directory of actual weight files, which the cache keys by commit
    /// hash. Nil when nothing usable has been downloaded.
    static func summarizerSnapshot(_ model: Model) -> URL? {
        guard let repo = Repo.ID(rawValue: model.id) else { return nil }
        let snapshots = summarizerCache.snapshotsDirectory(repo: repo, kind: .model)
        guard let revisions = try? FileManager.default.contentsOfDirectory(
            at: snapshots,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return revisions.first(where: directoryHasWeights)
    }

    public static func bytesOnDisk() -> Int64 {
        cacheDirectories().reduce(0) { $0 + directorySize($1) }
    }

    // MARK: Internals

    /// Mirror the layout WhisperKit uses under the download base we hand it, so
    /// presence can be checked without instantiating the pipeline, which would
    /// trigger the very download we are trying to ask about first.
    private static func whisperKitRoot() -> URL? {
        ModelStorage.downloadBase()
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
    }

    /// Each variant lands in a directory named exactly after itself.
    ///
    /// Note the absence of an `"openai_whisper-"` prefix: an earlier version
    /// built the path that way, which is right for the OpenAI conversions and
    /// wrong for the `distil-whisper_…` ones. Storing the full folder name in
    /// the variant removes the guess.
    private static func whisperDirectory(_ folder: String) -> URL? {
        whisperKitRoot()?.appendingPathComponent(folder, isDirectory: true)
    }

    private static func speakerKitDirectory() -> URL? {
        ModelStorage.downloadBase()
            .appendingPathComponent("models/argmaxinc/speakerkit-coreml", isDirectory: true)
    }

    /// A compiled CoreML model is a `.mlmodelc` directory. Finding one is a
    /// better presence test than checking the folder exists, because an
    /// interrupted download leaves the folder behind.
    ///
    /// Searched recursively because the SDKs nest differently: FluidAudio puts
    /// `.mlmodelc` directories at the top level, while SpeakerKit buries them
    /// three deep under `speaker_embedder/pyannote-v3/`.
    private static func directoryHasCompiledModels(_ directory: URL?, maxDepth: Int = 4) -> Bool {
        guard let directory, maxDepth > 0 else { return false }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return false }

        if contents.contains(where: { $0.lastPathComponent.hasSuffix(".mlmodelc") }) {
            return true
        }
        return contents.contains { child in
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return isDirectory && directoryHasCompiledModels(child, maxDepth: maxDepth - 1)
        }
    }

    /// MLX weights are loose files rather than a compiled CoreML bundle, so the
    /// `.mlmodelc` test above does not apply. Require both halves — weights and
    /// the config that describes them — for the same reason: an interrupted
    /// download leaves a directory that exists but cannot be loaded.
    static func directoryHasWeights(_ directory: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return false }

        let names = contents.map(\.lastPathComponent)
        return names.contains("config.json")
            && names.contains { $0.hasSuffix(".safetensors") }
    }

    private static func directorySize(_ directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}
