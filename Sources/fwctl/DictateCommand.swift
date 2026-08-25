import ArgumentParser
import Foundation
import FreeWhisperKit

struct Dictate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Record a short clip, transcribe it, and print or type the result."
    )

    @Option(name: .shortAndLong, help: "How long to listen, in seconds.")
    var seconds: Double = 5

    @Option(name: .shortAndLong, help: ModelOption.help)
    var model: String?

    @Option(help: ModelOption.deprecatedEngineHelp)
    var engine: String?

    @Flag(help: "Type the text into the frontmost app instead of printing it.")
    var insert = false

    @Option(help: "Transcribe this WAV instead of recording. For testing.")
    var file: String?

    func run() async throws {
        let speechModel = try ModelOption.resolve(
            model: model,
            engine: engine,
            or: ModelCatalog.defaultDictationTranscriber
        )

        if let file {
            try await transcribeAndDeliver(URL(fileURLWithPath: file), model: speechModel, deleteAfter: false)
            return
        }

        let recorder = DictationRecorder()
        try recorder.start()

        print("listening for \(seconds)s…")
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
            let bars = Int(min(1, max(0, recorder.level)) * 10)
            let meter = String(repeating: "#", count: bars) + String(repeating: ".", count: 10 - bars)
            print("  [\(meter)]\u{1B}[K\r", terminator: "")
            fflush(stdout)
        }
        print("")

        guard let url = recorder.stop() else {
            print("nothing captured (silence)")
            return
        }
        try await transcribeAndDeliver(url, model: speechModel, deleteAfter: true)
    }

    private func transcribeAndDeliver(
        _ url: URL,
        model: ModelCatalog.Model,
        deleteAfter: Bool
    ) async throws {
        defer { if deleteAfter { try? FileManager.default.removeItem(at: url) } }

        print("transcribing with \(model.name)…")
        let started = Date()
        let (asr, _) = await TranscriptionPipeline.engines(for: model)
        let segments = try await asr.transcribe(url: url, progress: nil)
        let text = segments.map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        print("took \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        print("")
        print(text.isEmpty ? "(no speech recognised)" : text)

        guard insert, !text.isEmpty else { return }
        print("")
        do {
            try TextInserter.insert(text)
            print("typed into the frontmost app")
            // Give the deferred clipboard restore time to run before we exit.
            try await Task.sleep(for: .seconds(1))
        } catch {
            print("could not type: \(error.localizedDescription)")
        }
    }
}
