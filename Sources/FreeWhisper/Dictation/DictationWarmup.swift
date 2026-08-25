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
///
/// Free to call repeatedly: `EngineRegistry` caches by model id and `prepare` is
/// single-flighted, so a warm model costs a lookup.
enum DictationWarmup {
    static func warm(_ model: ModelCatalog.Model) {
        // A cloud engine has no weights to warm, and preparing it would only log
        // a configuration error for anyone who has not set a key.
        guard model.engine?.isOnDevice == true else { return }
        Task.detached(priority: .utility) {
            await EngineRegistry.shared.preload(model)
        }
    }
}
