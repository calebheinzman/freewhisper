import ArgumentParser
import Foundation
import FreeWhisperKit

struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Transcribe and diarize a recorded meeting."
    )

    @Argument(help: "Meeting ID (directory name), or 'latest'.")
    var meeting: String = "latest"

    @Option(name: .shortAndLong, help: ModelOption.help)
    var model: String?

    @Option(help: ModelOption.deprecatedEngineHelp)
    var engine: String?

    @Flag(help: "Print the raw diarizer output before it is merged.")
    var showSpeakers = false

    func run() async throws {
        let speechModel = try ModelOption.resolve(model: model, engine: engine, or: ModelCatalog.defaultTranscriber)

        let store = MeetingStore.shared
        let id = try resolveMeetingID(store: store)
        guard let metadata = store.load(id: id) else {
            throw ValidationError("No meeting named '\(id)'.")
        }

        print("meeting: \(id)")
        print("model:   \(speechModel.name)")
        print("audio:   mic=\(metadata.hasMicAudio) system=\(metadata.hasSystemAudio) "
            + "offset=\(String(format: "%.3f", metadata.systemStreamOffset))s")
        print("")

        if showSpeakers {
            let diarizer = await EngineRegistry.shared.diarizer(for: speechModel)
            let turns = try await diarizer.diarize(
                url: store.paths(for: id).systemAudio,
                progress: nil
            )
            print("--- raw speaker turns (\(turns.count)) ---")
            for turn in turns {
                print(String(
                    format: "  %6.2f - %6.2f  %@",
                    turn.start, turn.end, turn.speakerID
                ))
            }
            let distinct = Set(turns.map(\.speakerID)).count
            print("  distinct speakers: \(distinct)\n")
        }

        let started = Date()
        let pipeline = TranscriptionPipeline(store: store)
        let transcript = try await pipeline.run(meetingID: id, model: speechModel) { progress in
            switch progress {
            case .downloadingModel(let name, _):
                // The SDKs give no cheap "already cached" signal, so this fires
                // on every run; word it so a cached run doesn't look wrong.
                print("  preparing \(name)… (first run downloads several hundred MB)")
            case .loadingModel(let name):
                print("  loading \(name)…")
            case .transcribing:
                print("  transcribing…")
            case .diarizing:
                print("  diarizing…")
            }
        }

        let elapsed = Date().timeIntervalSince(started)
        print("\n--- transcript (\(transcript.segments.count) segments in \(String(format: "%.1f", elapsed))s) ---\n")
        for segment in transcript.segments {
            let stamp = String(format: "%6.1f", segment.start)
            let speaker = transcript.name(for: segment.speakerID)
            print("[\(stamp)] \(speaker): \(segment.text)")
        }

        print("\nspeakers: \(transcript.speakerIDs.map { transcript.name(for: $0) }.joined(separator: ", "))")
        print("written:  \(store.paths(for: id).transcriptMarkdown.path)")
    }

    private func resolveMeetingID(store: MeetingStore) throws -> String {
        guard meeting == "latest" else { return meeting }
        guard let newest = store.list().first else {
            throw ValidationError("No meetings recorded yet. Try `fwctl record` first.")
        }
        return newest.id
    }
}

struct ListMeetings: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls",
        abstract: "List recorded meetings."
    )

    func run() throws {
        let store = MeetingStore.shared
        let meetings = store.list()
        guard !meetings.isEmpty else {
            print("no meetings yet")
            return
        }

        for meeting in meetings {
            let duration = String(format: "%5.1fs", meeting.duration)
            print("\(meeting.id.pad(34)) \(duration)  \(meeting.status.rawValue.pad(22)) \(meeting.displayTitle)")
        }

        let megabytes = Double(store.totalBytesOnDisk()) / 1_048_576
        print("\n\(meetings.count) meetings, \(String(format: "%.1f", megabytes)) MB in \(store.root.path)")
    }
}
