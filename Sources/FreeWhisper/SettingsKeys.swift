import Foundation
import FreeWhisperKit

/// UserDefaults keys shared between the coordinator and the SwiftUI views that
/// read them with @AppStorage.
enum SettingsKeys {
    /// The speech model meetings are transcribed with, as a `ModelCatalog` id.
    static let transcriptionModel = "transcriptionModel"
    /// The speech model dictation uses. Its own choice: dictation wants the
    /// text the moment you stop talking, meetings can afford to wait for
    /// accuracy, and the two ship with different defaults for that reason.
    static let dictationModel = "dictationModel"
    static let autoDetect = "autoDetectEnabled"
    static let autoTranscribe = "autoTranscribe"
    /// Seconds between detecting a meeting and starting to record. 0 means
    /// never auto-start — notify only, and wait for an explicit click.
    static let autoStartCountdown = "autoStartCountdown"
    static let watchedApps = "watchedApps"
    static let dictationMode = "dictationMode"
    /// The built-in ⌘⎋ hold-to-talk chord. On by default so dictation works
    /// with no configuration at all.
    static let chordEnabled = "dictationChordEnabled"
    /// Capture every display on one press, rather than just the one the pointer
    /// is on. On by default: a shared screen is often not on the display you're
    /// looking at when you reach for the key.
    static let screenshotAllDisplays = "screenshotAllDisplays"

    static func registerDefaults() {
        migrateEngineSelection()

        UserDefaults.standard.register(defaults: [
            transcriptionModel: ModelCatalog.defaultTranscriber.id,
            autoDetect: true,
            autoTranscribe: true,
            autoStartCountdown: 10,
            dictationModel: ModelCatalog.defaultDictationTranscriber.id,
            chordEnabled: true,
            screenshotAllDisplays: true,
        ])

        // Left behind by the version that installed ⌃⌥Space behind a one-shot
        // flag. Harmless, but its presence is misleading when debugging why a
        // shortcut is or isn't bound.
        UserDefaults.standard.removeObject(forKey: "dictationDefaultShortcutInstalled")
    }

    /// Carries forward the engine choice made by builds that selected an engine
    /// rather than a model.
    ///
    /// Written to new keys rather than reinterpreting the old ones: two value
    /// spaces behind one key means a stored value that fails to parse, and a
    /// user quietly reset to the default is exactly the failure this avoids.
    /// The old keys are read once and left alone — cheap, and they are the only
    /// record of the choice if this ever has to be re-run.
    private static func migrateEngineSelection() {
        let defaults = UserDefaults.standard
        let legacy = [
            ("engine", transcriptionModel),
            ("dictationEngine", dictationModel),
        ]

        for (old, new) in legacy {
            guard defaults.string(forKey: new) == nil,
                  let raw = defaults.string(forKey: old),
                  let model = ModelCatalog.transcriber(migratingEngine: raw)
            else { continue }
            defaults.set(model.id, forKey: new)
        }
    }
}
