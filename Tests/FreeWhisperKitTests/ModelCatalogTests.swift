import Foundation
import Testing

@testable import FreeWhisperKit

@Suite("Model catalog")
struct ModelCatalogTests {
    /// Every engine that can be selected has to be able to label speakers,
    /// including cloud — which returns text with no attribution and so borrows
    /// a local diarizer.
    @Test("every engine pairs with a diarizer that exists")
    func everyEngineHasADiarizer() {
        for engine in EngineKind.allCases {
            let diarizer = ModelCatalog.diarizer(for: engine)
            #expect(diarizer.isDiarizer)
            #expect(ModelCatalog.diarizers.contains(diarizer))
        }
        #expect(ModelCatalog.diarizer(for: .cloud) == ModelCatalog.speakerKitDiarizer)
    }

    @Test("the cloud entry has no weights to download")
    func cloudNeedsNoModels() {
        #expect(ModelCatalog.cloudTranscription.isWeightless)
        #expect(ModelCatalog.cloudTranscription.approximateBytes == 0)
        // Reported present because there is nothing to fetch — otherwise it
        // would sit in the list forever offering a Download button that does
        // nothing.
        #expect(ModelCatalog.isDownloaded(ModelCatalog.cloudTranscription))
        #expect(ModelCatalog.directory(for: ModelCatalog.cloudTranscription) == nil)
        #expect(ModelCatalog.transcribers.filter(\.isWeightless).count == 1)
    }

    /// `WhisperKit.download(variant:)` searches the repo with the glob
    /// `*<variant>/*` and throws when more than one folder matches. A folder
    /// name that is a prefix of another is therefore unfetchable — and it fails
    /// at download time, on a user's machine, rather than at build time here.
    @Test("no Whisper variant name is a prefix of another")
    func whisperVariantsAreUnambiguous() {
        let folders = ModelCatalog.transcribers.compactMap { model -> String? in
            guard case .whisper(let folder) = model.variant else { return nil }
            return folder
        }
        #expect(folders.count >= 3)

        for folder in folders {
            let collisions = folders.filter { $0 != folder && $0.hasPrefix(folder) }
            #expect(collisions.isEmpty, "\(folder) is a prefix of \(collisions)")
        }
    }

    /// An earlier version built this path as `"openai_whisper-" + variant`,
    /// which is right for the OpenAI conversions and wrong for the distilled
    /// ones. The variant now carries the whole folder name.
    @Test("a variant's directory is named after the variant, with nothing prepended")
    func whisperDirectoriesMatchTheirVariant() {
        for model in ModelCatalog.transcribers {
            guard case .whisper(let folder) = model.variant else { continue }
            let directory = ModelCatalog.directory(for: model)
            #expect(directory?.lastPathComponent == folder, "\(model.id) resolved to \(directory?.path ?? "nil")")
        }

        let distil = ModelCatalog.directory(for: ModelCatalog.distilWhisper)
        #expect(distil?.lastPathComponent.hasPrefix("distil-whisper") == true)
    }

    /// The catalog id is what lands in UserDefaults. An upstream rename must
    /// not be able to deselect somebody's model, which is why the id is ours
    /// and not the folder or repo name.
    @Test("speech ids are ours, not upstream paths")
    func speechIDsAreStable() {
        for model in ModelCatalog.transcribers {
            #expect(!model.id.contains("/"), "\(model.id) looks like a repo path")
            if case .whisper(let folder) = model.variant {
                #expect(model.id != folder)
            }
        }
    }

    /// Selecting an engine was the only choice older builds could persist, and
    /// there was exactly one model per engine — so nobody's choice may change
    /// under them on upgrade.
    @Test("the old engine selection maps onto the model that replaced it")
    func engineMigrationIsExact() {
        #expect(ModelCatalog.transcriber(migratingEngine: "whisperKit") == ModelCatalog.whisperTurbo)
        #expect(ModelCatalog.transcriber(migratingEngine: "fluidAudio") == ModelCatalog.parakeetV3)
        #expect(ModelCatalog.transcriber(migratingEngine: "cloud") == ModelCatalog.cloudTranscription)
        #expect(ModelCatalog.transcriber(migratingEngine: "nonsense") == nil)

        // Every engine that was selectable has somewhere to land.
        for engine in EngineKind.allCases {
            #expect(ModelCatalog.transcriber(migratingEngine: engine.rawValue) != nil)
        }
    }

    /// A stored id from a retired model, or from a newer build, has to leave
    /// the user with something that works rather than with nothing selected.
    @Test("an unknown stored id falls back instead of failing")
    func unknownSelectionFallsBack() {
        #expect(ModelCatalog.transcriber(id: nil, or: ModelCatalog.whisperTurbo) == ModelCatalog.whisperTurbo)
        #expect(ModelCatalog.transcriber(id: "retired", or: ModelCatalog.parakeetV3) == ModelCatalog.parakeetV3)
        #expect(
            ModelCatalog.transcriber(id: ModelCatalog.distilWhisper.id, or: ModelCatalog.whisperTurbo)
                == ModelCatalog.distilWhisper
        )
        // Diarizers and summarizers are not speech choices, so their ids must
        // not resolve here even though they are in the same catalog.
        #expect(
            ModelCatalog.transcriber(id: ModelCatalog.speakerKitDiarizer.id, or: ModelCatalog.whisperTurbo)
                == ModelCatalog.whisperTurbo
        )
    }

    /// Both new Whisper entries are larger than the one that ships. Pulling
    /// either on first run would double an already slow setup.
    @Test("the added models are all opt-in")
    func addedModelsAreOptIn() {
        let added = [
            ModelCatalog.whisperLargeV3,
            ModelCatalog.distilWhisper,
            ModelCatalog.parakeet110M,
        ]
        for model in added {
            #expect(!ModelCatalog.defaults.contains(model), "\(model.id) is in the first-run download")
        }
    }

    @Test("model ids are unique")
    func idsAreUnique() {
        let ids = ModelCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    /// The defaults have to cover the shipped configuration exactly: Whisper
    /// for meetings with its diarizer, and Parakeet for dictation. Miss one and
    /// the first meeting stalls on an unexpected download.
    @Test("defaults cover the shipped configuration")
    func defaultsCoverShippedConfiguration() {
        let defaults = ModelCatalog.defaults

        #expect(defaults.contains(ModelCatalog.defaultTranscriber))
        #expect(defaults.contains(ModelCatalog.speakerKitDiarizer))
        #expect(defaults.contains(ModelCatalog.defaultDictationTranscriber))

        // The two roles ship with different models on purpose — accuracy for
        // meetings, latency for dictation — so a change that collapsed them
        // into one would quietly make one of the two features worse.
        #expect(ModelCatalog.defaultTranscriber != ModelCatalog.defaultDictationTranscriber)
    }

    /// Dictation never diarizes and meetings default to Whisper, so FluidAudio's
    /// diarizer is only reachable after the user switches engines. Downloading
    /// it up front would be 13 MB nobody asked for.
    @Test("the diarizer no default configuration uses is opt-in")
    func unusedDiarizerIsOptIn() {
        #expect(!ModelCatalog.defaults.contains(ModelCatalog.fluidAudioDiarizer))
    }

    @Test("total size sums the models given")
    func totalBytesSums() {
        let total = ModelCatalog.totalBytes([
            ModelCatalog.whisperTurbo,
            ModelCatalog.speakerKitDiarizer,
        ])
        #expect(total == ModelCatalog.whisperTurbo.approximateBytes
            + ModelCatalog.speakerKitDiarizer.approximateBytes)
        #expect(ModelCatalog.totalBytes([]) == 0)
    }

    @Test("sizes are rendered for humans")
    func sizeFormatting() {
        #expect(ModelCatalog.whisperTurbo.approximateSize.contains("MB"))
    }

    @Test("missing never reports a model outside the defaults")
    func missingIsScopedToDefaults() {
        #expect(ModelCatalog.missingDefaults.allSatisfy { ModelCatalog.defaults.contains($0) })
    }

    /// Summarization ships off, and the built-in model is over 2 GB. Pulling it
    /// down on first launch for a feature nobody has turned on would be the
    /// single worst thing this app could do to a new user's connection.
    @Test("summarization models are never part of the first-run download")
    func summarizersAreOptIn() {
        #expect(ModelCatalog.defaults.allSatisfy { !$0.isSummarizer })
        #expect(ModelCatalog.missingDefaults.allSatisfy { !$0.isSummarizer })
    }

    /// The catalog id doubles as the HuggingFace repo id, which is what makes
    /// it stable across releases — and what `LLMProvider.onDevice` stores.
    @Test("summarization ids are HuggingFace repo ids")
    func summarizerIDsAreRepoIDs() {
        for model in ModelCatalog.summarizers {
            #expect(model.id.split(separator: "/").count == 2, "\(model.id) is not org/name")
            // Every model on this list is a 4-bit conversion, and dropping the
            // suffix names a repo that either doesn't exist or isn't the one we
            // sized. That mistake is invisible until a user tries to download.
            #expect(model.id.hasSuffix("-4bit"), "\(model.id) is not a 4-bit conversion")
        }
        #expect(ModelCatalog.summarizers.contains(ModelCatalog.defaultSummarizer))
        #expect(LLMProvider.onDevice.model == ModelCatalog.defaultSummarizer.id)
    }

    /// Users of MLX or Python tooling can have tens of gigabytes in the shared
    /// HuggingFace cache. Adding to it — and deleting from it when they press
    /// Remove — is not ours to do.
    @Test("summarization models live in a cache of ours, not the shared one")
    func summarizersAreSelfHosted() {
        let directory = ModelCatalog.summarizerRepoDirectory(ModelCatalog.defaultSummarizer)
        #expect(directory.path.contains("FreeWhisper/Models"))
        #expect(!directory.path.contains(".cache/huggingface"))
        #expect(directory.lastPathComponent == "models--mlx-community--Qwen3-4B-Instruct-2507-4bit")
    }

    @Test("every model resolves to a cache directory it can be removed from")
    func everyModelHasADirectory() {
        // Cloud excepted: there is nothing on disk to point at.
        for model in ModelCatalog.all where !model.isWeightless {
            #expect(ModelCatalog.directory(for: model) != nil, "\(model.id) has no directory")
        }
    }

    @Test("defaultsAreReady agrees with the per-model checks")
    func readinessIsConsistent() {
        let allPresent = ModelCatalog.defaults.allSatisfy(ModelCatalog.isDownloaded)
        #expect(ModelCatalog.defaultsAreReady == allPresent)
    }

    /// WhisperKit and SpeakerKit default to ~/Documents/huggingface when handed
    /// no download base. That raises a Documents-folder TCC prompt mid-download
    /// on an unsandboxed app, and syncs ~640 MB to iCloud Drive for anyone with
    /// Desktop & Documents turned on. Nothing we manage belongs there.
    @Test("no model is stored in the user's Documents folder")
    func nothingLivesInDocuments() {
        let documents = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first!.path
        for directory in ModelCatalog.cacheDirectories() {
            #expect(
                !directory.standardizedFileURL.path.hasPrefix(documents),
                "\(directory.path) is under Documents"
            )
        }
    }

    @Test("the speech download base sits with the rest of our app data")
    func downloadBaseIsAppSupport() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.path
        let base = ModelStorage.downloadBase().standardizedFileURL.path
        #expect(base.hasPrefix(support))
        #expect(base.contains("FreeWhisper/Models"))
    }

    @Test("migration moves the old Documents tree without re-downloading")
    func migrationMovesWeights() throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let legacy = sandbox.appendingPathComponent("Documents/huggingface")
        let newBase = sandbox.appendingPathComponent("Application Support/FreeWhisper/Models/huggingface")
        defer { try? fm.removeItem(at: sandbox) }

        let repo = legacy.appendingPathComponent("models/argmaxinc/whisperkit-coreml")
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: repo.appendingPathComponent("model.mlmodelc"))
        // WhisperKit caches the tokenizer under the upstream account, separately
        // from the CoreML weights. Moving only the weights orphans this.
        let tokenizer = legacy.appendingPathComponent("models/openai/whisper-large-v3")
        try fm.createDirectory(at: tokenizer, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: tokenizer.appendingPathComponent("tokenizer.json"))

        let defaults = UserDefaults(suiteName: "migration-\(UUID().uuidString)")!
        ModelStorage.migrateFromDocumentsIfNeeded(from: legacy, to: newBase, defaults: defaults)

        let moved = newBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml/model.mlmodelc")
        let movedTokenizer = newBase.appendingPathComponent("models/openai/whisper-large-v3/tokenizer.json")
        #expect(fm.fileExists(atPath: moved.path))
        #expect(fm.fileExists(atPath: movedTokenizer.path), "the tokenizer cache was left behind")
        #expect(!fm.fileExists(atPath: legacy.path), "the emptied legacy tree should be pruned")
        #expect(defaults.bool(forKey: "models.migratedFromDocuments"))
    }

    /// Everything else under ~/Documents/huggingface belongs to whatever other
    /// tooling put it there. Emptying our own subtree must not take it with us.
    @Test("migration leaves other tooling's models alone")
    func migrationSparesForeignRepos() throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let legacy = sandbox.appendingPathComponent("Documents/huggingface")
        let newBase = sandbox.appendingPathComponent("Application Support/Models")
        defer { try? fm.removeItem(at: sandbox) }

        let ours = legacy.appendingPathComponent("models/argmaxinc/speakerkit-coreml")
        let theirs = legacy.appendingPathComponent("models/meta-llama/Llama-3.1-8B")
        try fm.createDirectory(at: ours, withIntermediateDirectories: true)
        try fm.createDirectory(at: theirs, withIntermediateDirectories: true)

        let defaults = UserDefaults(suiteName: "migration-\(UUID().uuidString)")!
        ModelStorage.migrateFromDocumentsIfNeeded(from: legacy, to: newBase, defaults: defaults)

        #expect(fm.fileExists(atPath: theirs.path), "a foreign repo was deleted")
        #expect(fm.fileExists(
            atPath: newBase.appendingPathComponent("models/argmaxinc/speakerkit-coreml").path
        ))
    }

    /// The flag is what stops this running on every launch, so it has to be set
    /// even on a fresh install where there was nothing to move.
    @Test("migration records itself when there is nothing to move")
    func migrationIsIdempotent() {
        let defaults = UserDefaults(suiteName: "migration-\(UUID().uuidString)")!
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        ModelStorage.migrateFromDocumentsIfNeeded(from: empty, to: empty, defaults: defaults)
        #expect(defaults.bool(forKey: "models.migratedFromDocuments"))
    }
}
