import Foundation
import FreeWhisperKit

/// Loads a dictation model's weights in the background, before they are needed.
///
/// Dictation's whole value is that the text appears the moment you stop talking,
/// and a cold CoreML load is nowhere near that fast: measured on an M1 Max, a
/// first-ever load is about 170 seconds for Whisper large-v3 and 774 for
/// Distil-Whisper, against a quarter of a second for Parakeet. Those numbers are
/// paid once per model per machine, but paying them *in front of the hotkey* is
/// indistinguishable from the app being broken.
///
/// This used to run only at launch, for whichever model was selected then, which
/// is why Parakeet 0.6B — the default — appeared to be the only Voice to Text
/// model that worked. It now also runs when the user picks a different one, so
/// the load happens while they are still in Settings.
@MainActor
enum DictationWarmup {
    private static var pending: Task<Void, Never>?

    /// How long the selection has to hold still before its weights are loaded.
    ///
    /// Picking a model is exactly how you browse the list, and loading one set of
    /// weights per row visited is worse than loading none: several CoreML models
    /// resident at once contend hard enough to slow an unrelated transcription
    /// by an order of magnitude — measured at 392 seconds against 40 for the same
    /// clip. So settle first, then load.
    private static let settleDelay = Duration.milliseconds(600)

    static func warm(_ model: ModelCatalog.Model) {
        // Supersede rather than stack. Cancelling will not interrupt a CoreML
        // load already in flight — it never checks — but it does stop the ones
        // still waiting out the delay, which is where rapid clicking lands.
        pending?.cancel()

        // A cloud engine has no weights to warm, and preparing it would only log
        // a configuration error for anyone who has not set a key. Still worth
        // evicting the others, so switching to cloud frees the memory.
        // The meeting model is kept too: evicting it here would just move the
        // cold load onto the next transcription.
        let meetingModel = ModelCatalog.transcriber(
            id: UserDefaults.standard.string(forKey: SettingsKeys.transcriptionModel),
            or: ModelCatalog.defaultTranscriber
        )
        let keep = Set([model.id, meetingModel.id])

        pending = Task { [keep] in
            try? await Task.sleep(for: settleDelay)
            guard !Task.isCancelled else { return }
            await EngineRegistry.shared.keepOnly(keep)
            guard model.engine?.isOnDevice == true else { return }
            await EngineRegistry.shared.preload(model)
        }
    }
}
