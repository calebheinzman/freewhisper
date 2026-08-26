import ArgumentParser
import Foundation
import FreeWhisperKit

/// Runs the shipped models over benchmark corpora and records what they produced
/// and what it cost.
///
/// This half deliberately does no scoring. Every metric worth reporting — WER,
/// DER, tcpWER, an LLM-judged rubric — has a canonical Python implementation
/// that took years to get right, and reimplementing any of them in Swift would
/// buy a single binary at the price of numbers nobody could check against the
/// literature. So Swift runs the models, because Swift is where the engines are,
/// and `eval/` scores the output.
@main
struct FWEval: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fweval",
        abstract: "Run speech and summary models over an evaluation corpus.",
        discussion: """
        Reads a manifest produced by eval/prepare, writes one JSON per item into \
        --out, and skips items already there so an interrupted run resumes.

        Build release before using this for timings: FluidAudio mirrors its logs \
        to stdout under DEBUG, and a debug binary is not the thing users run.
        """,
        subcommands: [ASR.self, Meeting.self, Summarize.self]
    )
}

/// Shared plumbing for the three tracks.
enum Runner {
    /// Iterates a manifest, writing one result file per item.
    ///
    /// Two things this owes the caller. It never throws for a single bad item:
    /// a corpus of a few hundred clips will contain one that fails to decode,
    /// and losing two hours of completed work to it is not acceptable. And it
    /// skips items already on disk, which is what makes a run resumable and
    /// makes adding one model re-run only that model.
    static func each(
        manifest: Manifest,
        model: String,
        out: URL,
        force: Bool,
        body: (Manifest.Item) async throws -> ItemResult
    ) async throws -> RunResult {
        var completed = 0
        var failed = 0
        let overall = Stopwatch()

        for (index, item) in manifest.items.enumerated() {
            let destination = Output.path(in: out, id: item.id)
            if !force, FileManager.default.fileExists(atPath: destination.path) {
                continue
            }

            let progress = "[\(index + 1)/\(manifest.items.count)] \(item.id)"
            do {
                let result = try await body(item)
                try Output.write(result, to: destination)
                completed += 1
                let rtfx = result.rtfx.map { String(format: " (%.1f× realtime)", $0) } ?? ""
                print("\(progress) \(String(format: "%.1fs", result.wallSeconds))\(rtfx)")
            } catch {
                failed += 1
                let message = "\(error)"
                try Output.write(
                    ItemResult(
                        id: item.id, model: model, dataset: manifest.dataset, track: manifest.track,
                        wallSeconds: 0, error: message
                    ),
                    to: destination
                )
                print("\(progress) FAILED: \(message)")
            }
            fflush(stdout)
        }

        return RunResult(
            model: model,
            dataset: manifest.dataset,
            track: manifest.track,
            modelLoadSeconds: 0,
            totalWallSeconds: overall.seconds,
            itemCount: completed,
            failureCount: failed,
            host: .current()
        )
    }

    static func finish(_ run: RunResult, loadSeconds: Double, out: URL) throws {
        var run = run
        run.modelLoadSeconds = loadSeconds
        try Output.write(run, to: out.appendingPathComponent("_run.json"))
        print("""

        \(run.model) on \(run.dataset): \(run.itemCount) done, \(run.failureCount) failed, \
        model load \(String(format: "%.1fs", loadSeconds))
        """)
    }

    /// Resolves a `--model` id against the catalog, in the same shape `fwctl`
    /// uses, so an unknown id lists the options rather than failing obscurely.
    static func transcriber(_ id: String) throws -> ModelCatalog.Model {
        guard let model = ModelCatalog.transcribers.first(where: { $0.id == id }) else {
            throw ValidationError(
                "Unknown model '\(id)'. Options: \(ModelCatalog.transcribers.map(\.id).joined(separator: ", "))"
            )
        }
        return model
    }
}

/// Flags every track shares.
struct CommonOptions: ParsableArguments {
    @Option(name: .long, help: "Manifest JSON from eval/prepare.", transform: URL.init(fileURLWithPath:))
    var manifest: URL

    @Option(name: .long, help: "Model id to evaluate.")
    var model: String

    @Option(name: .long, help: "Directory for the per-item results.", transform: URL.init(fileURLWithPath:))
    var out: URL

    @Flag(name: .long, help: "Re-run items that already have a result file.")
    var force = false
}
