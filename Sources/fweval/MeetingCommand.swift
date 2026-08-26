import ArgumentParser
import Foundation
import FreeWhisperKit

/// The full meeting pipeline: ASR, diarization and assembly.
///
/// Runs the real ``TranscriptionPipeline`` rather than calling the two engines
/// by hand, because a good deal of what determines transcript quality lives
/// between them — `TranscriptAssembler` attributes each segment to a speaker by
/// time overlap, suppresses echo, and numbers the speakers. Scoring the engines
/// in isolation would report a diarization quality the user never receives.
///
/// Benchmark corpora are single-file, so the audio is fed through the *system*
/// channel and the mic channel is left empty. That is the honest arrangement:
/// the mic channel is the local user by definition and needs no diarizing, so
/// what gets measured here is the diarizer, not the channel-split heuristic.
struct Meeting: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "meeting",
        abstract: "Transcribe and diarize each meeting in a manifest."
    )

    @OptionGroup var options: CommonOptions

    func run() async throws {
        let model = try Runner.transcriber(options.model)
        let manifest = try Manifest.load(options.manifest)

        // A scratch store rather than the real one. `MeetingStore(root:)` takes
        // an injectable root, so an eval run never writes into the user's
        // Application Support directory or shows up in their meeting list.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fweval-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingStore(root: root)
        let pipeline = TranscriptionPipeline(store: store)

        print("loading \(model.name) and its diarizer…")
        let loading = Stopwatch()
        let (asr, diarizer) = await TranscriptionPipeline.engines(for: model)
        try await asr.prepare(progress: nil)
        try await diarizer.prepare(progress: nil)

        // Both halves need a real inference to finish compiling — see
        // `Audio.warmupFile`. Doing it on three seconds of tone rather than on
        // the first meeting keeps a quarter-hour of audio out of the load figure.
        let warmup = try Audio.warmupFile()
        _ = try? await asr.transcribe(url: warmup, progress: nil)
        _ = try? await diarizer.diarize(url: warmup, progress: nil)
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
            let meetingID = Output.sanitize(item.id)

            try stage(url, as: meetingID, in: store)

            let clock = Stopwatch()
            let transcript = try await pipeline.run(meetingID: meetingID, model: model, progress: nil)
            let wall = clock.seconds

            // Outside the stopwatch, and a second pass over the same audio.
            // The pipeline diarizes internally and keeps the turns to itself, so
            // the only way to see what the diarizer actually said is to ask it
            // again. Diarization is a few percent of the total here, and paying
            // it twice buys the one number in this suite that can be checked
            // against somebody else's published result.
            let turns = try? await diarizer.diarize(url: url, progress: nil)

            return ItemResult(
                id: item.id,
                model: model.id,
                dataset: manifest.dataset,
                track: manifest.track,
                text: transcript.segments.map(\.text).joined(separator: " "),
                segments: transcript.segments.map {
                    .init(start: $0.start, end: $0.end, speaker: $0.speakerID, text: $0.text)
                },
                speakerTurns: turns?.map {
                    .init(start: $0.start, end: $0.end, speaker: $0.speakerID)
                },
                audioSeconds: duration,
                wallSeconds: wall,
                rtfx: wall > 0 ? duration / wall : nil
            )
        }

        try Runner.finish(run, loadSeconds: loadSeconds, out: options.out)
    }

    /// Lays out a meeting directory the pipeline will accept.
    ///
    /// `run` refuses to start without a `meta.json`, so the eval audio is copied
    /// in as `system.wav` beside metadata claiming a system-only capture.
    /// `micStartedAt` stays nil, which makes `systemStreamOffset` zero — the
    /// segment timestamps then come back on the audio's own clock, which is what
    /// the reference RTTM is measured against.
    private func stage(_ audio: URL, as meetingID: String, in store: MeetingStore) throws {
        let paths = store.paths(for: meetingID)
        try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: paths.systemAudio)
        try FileManager.default.copyItem(at: audio, to: paths.systemAudio)

        let started = Date()
        try store.save(MeetingMetadata(
            id: meetingID,
            title: meetingID,
            startedAt: started,
            endedAt: started,
            systemStartedAt: started,
            hasMicAudio: false,
            hasSystemAudio: true,
            status: .awaitingTranscription
        ))
    }
}
