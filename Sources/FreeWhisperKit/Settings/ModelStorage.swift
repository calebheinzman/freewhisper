import Foundation
import OSLog

/// Where the CoreML speech models live.
///
/// WhisperKit and SpeakerKit both default to `~/Documents/huggingface` when no
/// download base is given, which is wrong for us in three ways: the app is not
/// sandboxed, so writing there raises a "would like to access files in your
/// Documents folder" prompt in the middle of the first-run download; it syncs
/// ~640 MB to iCloud Drive for anyone with Desktop & Documents turned on; and it
/// looks like the app is littering in a folder the user actually opens.
///
/// Pointing them at Application Support instead puts every model we manage under
/// one directory — the MLX summarizer weights already live beside this, under
/// the same `FreeWhisper/Models` parent — which is also what lets an uninstall
/// be a single line.
public enum ModelStorage {
    /// Hub cache root handed to WhisperKit and SpeakerKit as their download base.
    /// They lay out `<base>/models/<repo-id>` underneath it themselves.
    public static func downloadBase() -> URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("FreeWhisper/Models/huggingface", isDirectory: true)
    }

    /// Where those two SDKs put things before we started passing a download base.
    public static func legacyDownloadBase() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("huggingface", isDirectory: true)
    }

    private static let migrationKey = "models.migratedFromDocuments"

    /// Moves an existing `~/Documents/huggingface` tree under Application Support.
    ///
    /// Safe to do behind the user's back: the Hub's `.metadata` sidecars record a
    /// commit hash, an etag and a timestamp, and no absolute paths, so a moved
    /// tree still reads as a valid cache and nothing is re-downloaded. Same
    /// volume, so the move is a rename rather than 640 MB of copying.
    ///
    /// Idempotent, and deliberately quiet about failure: a machine where this
    /// does not work is one that re-downloads, which is slow but not broken.
    /// The roots are parameters so this can be tested without touching the real
    /// Documents folder — which, on a machine that has run an older build, holds
    /// the user's actual weights.
    public static func migrateFromDocumentsIfNeeded(
        from legacy: URL? = legacyDownloadBase(),
        to newBase: URL = downloadBase(),
        defaults: UserDefaults = .standard
    ) {
        guard !defaults.bool(forKey: migrationKey) else { return }
        defer { defaults.set(true, forKey: migrationKey) }

        let fm = FileManager.default
        guard let legacy else { return }
        let legacyModels = legacy.appendingPathComponent("models", isDirectory: true)
        guard fm.fileExists(atPath: legacyModels.path) else { return }

        let newModels = newBase.appendingPathComponent("models", isDirectory: true)
        do {
            for owner in try fm.contentsOfDirectory(atPath: legacyModels.path) {
                guard ownedAccounts.contains(owner) else { continue }
                let fromOwner = legacyModels.appendingPathComponent(owner, isDirectory: true)
                let toOwner = newModels.appendingPathComponent(owner, isDirectory: true)
                try fm.createDirectory(at: toOwner, withIntermediateDirectories: true)

                for repo in try fm.contentsOfDirectory(atPath: fromOwner.path) {
                    guard !repo.hasPrefix(".") else { continue }
                    let from = fromOwner.appendingPathComponent(repo, isDirectory: true)
                    let to = toOwner.appendingPathComponent(repo, isDirectory: true)
                    // A destination that already exists is the authority. Leave
                    // the stale copy rather than clobbering good weights.
                    guard !fm.fileExists(atPath: to.path) else { continue }
                    try fm.moveItem(at: from, to: to)
                    Log.transcription.notice(
                        "moved \(owner, privacy: .public)/\(repo, privacy: .public) out of Documents"
                    )
                }
                if isEffectivelyEmpty(fromOwner) { try? fm.removeItem(at: fromOwner) }
            }
            // Prune upwards, but only through directories we emptied. Anything
            // still down there belongs to other tooling and is not ours to delete.
            for directory in [legacyModels, legacy] {
                guard isEffectivelyEmpty(directory) else { break }
                try? fm.removeItem(at: directory)
            }
        } catch {
            Log.transcription.error(
                "model migration failed: \(error.localizedDescription, privacy: .public)"
            )
        }

        excludeFromBackup()
    }

    /// HuggingFace accounts whose repos under the old download base are ours.
    ///
    /// `argmaxinc` holds the CoreML weights for WhisperKit and SpeakerKit;
    /// `openai` and `distil-whisper` hold the tokenizer configs WhisperKit pulls
    /// alongside them, which is why moving only the weights left a stub behind.
    /// Anything outside this list stays put — another tool may have chosen the
    /// same default download base, and its data is not ours to move.
    private static let ownedAccounts: Set<String> = ["argmaxinc", "openai", "distil-whisper"]

    /// Empty apart from the `.DS_Store` Finder leaves behind after the user has
    /// once opened the folder — which, this being Documents, they will have.
    private static func isEffectivelyEmpty(_ directory: URL) -> Bool {
        guard let entries = try? FileManager.default
            .contentsOfDirectory(atPath: directory.path) else { return false }
        return entries.allSatisfy { $0 == ".DS_Store" }
    }

    /// A gigabyte of weights that can be fetched again does not belong in every
    /// Time Machine snapshot.
    public static func excludeFromBackup() {
        var root = downloadBase()
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
    }
}
