import ArgumentParser
import Foundation
import FreeWhisperKit

/// Raw speech-to-text over short clips: the dictation track.
///
/// Goes straight to the engine rather than through ``TranscriptionPipeline``,
/// because that is exactly what `DictationController` does — it takes the ASR
/// half of `engines(for:)` and throws the diarizer away. Evaluating dictation
/// through the meeting pipeline would measure a code path the ⌘⎋ hotkey never
/// touches.
struct ASR: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "asr",
        abstract: "Transcribe each clip in a manifest. Dictation accuracy and latency."
    )

    @OptionGroup var options: CommonOptions

    func run() async throws {
        let model = try Runner.transcriber(options.model)
        let manifest = try Manifest.load(options.manifest)

        // Loading is timed on its own and paid once, matching the app: the
        // registry caches by model id, so only the first dictation of a session
        // waits for weights.
        print("loading \(model.name)…")
        let loading = Stopwatch()
        let engine = await EngineRegistry.shared.transcriber(for: model)
        try await engine.prepare(progress: nil)

        // See `Audio.warmupFile`: `prepare()` alone leaves CoreML compilation to
        // the first real inference, which would be charged to item one.
        let warmup = try Audio.warmupFile()
        _ = try? await engine.transcribe(url: warmup, progress: nil)
        try? FileManager.default.removeItem(at: warmup)

        let loadSeconds = loading.seconds
        print("ready in \(String(format: "%.1fs", loadSeconds))\n")

        let run = try await Runner.each(
            manifest: manifest,
            model: model.id,
            out: options.out,
            force: options.force
        ) { item in
            guard let audio = item.audio else {
                throw ValidationError("item \(item.id) has no audio")
            }
            let url = URL(fileURLWithPath: audio)
            let duration = try Audio.duration(of: url)

            let clock = Stopwatch()
            let segments = try await engine.transcribe(url: url, progress: nil)
            let wall = clock.seconds

            return ItemResult(
                id: item.id,
                model: model.id,
                dataset: manifest.dataset,
                track: manifest.track,
                // Joined exactly the way `DictationController` joins it, so the
                // string being scored is the string that would land in the
                // user's text field.
                text: segments.map(\.text)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                audioSeconds: duration,
                wallSeconds: wall,
                rtfx: wall > 0 ? duration / wall : nil
            )
        }

        try Runner.finish(run, loadSeconds: loadSeconds, out: options.out)
    }
}
