import Foundation

/// Runs a finished recording through ASR, diarization and assembly.
public struct TranscriptionPipeline: Sendable {
    private let store: MeetingStore
    private let screenshots: ScreenshotStore

    public init(store: MeetingStore = .shared) {
        self.store = store
        self.screenshots = ScreenshotStore(store: store)
    }

    /// Shared, model-loading instances. Always go through the registry rather
    /// than constructing an engine — a fresh one reloads its weights.
    public static func engines(
        for model: ModelCatalog.Model
    ) async -> (any TranscriptionEngine, any DiarizationEngine) {
        await (
            EngineRegistry.shared.transcriber(for: model),
            EngineRegistry.shared.diarizer(for: model)
        )
    }

    @discardableResult
    public func run(
        meetingID: String,
        model: ModelCatalog.Model,
        progress: ProgressHandler? = nil
    ) async throws -> Transcript {
        guard var metadata = store.load(id: meetingID) else {
            throw TranscriptionError.audioFileMissing(store.paths(for: meetingID).directory)
        }

        let paths = store.paths(for: meetingID)
        metadata.status = .transcribing
        // The model id, not the engine: "whisper-large-v3-turbo" says which
        // weights produced this transcript, where "whisperKit" no longer does.
        metadata.transcriptionEngine = model.id
        try? store.save(metadata)

        do {
            let transcript = try await transcribe(paths: paths, metadata: metadata, model: model, progress: progress)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(transcript).write(to: paths.transcriptJSON, options: .atomic)
            try transcript
                .markdown(
                    title: metadata.displayTitle,
                    screenshots: screenshots.load(meetingID: meetingID)
                )
                .write(to: paths.transcriptMarkdown, atomically: true, encoding: .utf8)

            metadata.status = .complete
            try? store.save(metadata)
            Log.transcription.info("transcribed \(meetingID, privacy: .public): \(transcript.segments.count, privacy: .public) segments")
            return transcript
        } catch {
            metadata.status = .failed
            try? store.save(metadata)
            throw error
        }
    }

    private func transcribe(
        paths: MeetingPaths,
        metadata: MeetingMetadata,
        model: ModelCatalog.Model,
        progress: ProgressHandler?
    ) async throws -> Transcript {
        let (asr, diarizer) = await Self.engines(for: model)
        let fileManager = FileManager.default

        var micSegments: [RawSegment] = []
        var systemSegments: [RawSegment] = []
        var systemTurns: [SpeakerTurn] = []

        if metadata.hasMicAudio, fileManager.fileExists(atPath: paths.micAudio.path) {
            micSegments = try await asr.transcribe(url: paths.micAudio, progress: progress)
        }

        if metadata.hasSystemAudio, fileManager.fileExists(atPath: paths.systemAudio.path) {
            systemSegments = try await asr.transcribe(url: paths.systemAudio, progress: progress)

            // Diarization is only worth running when there is remote speech to
            // split, and a failure here shouldn't cost us the transcript — an
            // unlabelled transcript beats none.
            if !systemSegments.isEmpty {
                do {
                    systemTurns = try await diarizer.diarize(url: paths.systemAudio, progress: progress)
                } catch {
                    Log.transcription.error("diarization failed, continuing unlabelled: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        guard !micSegments.isEmpty || !systemSegments.isEmpty else {
            throw TranscriptionError.engineFailed(
                engine: model.name,
                reason: "no speech was recognised in either channel"
            )
        }

        return TranscriptAssembler.assemble(.init(
            micSegments: micSegments,
            systemSegments: systemSegments,
            systemTurns: systemTurns,
            systemOffset: metadata.systemStreamOffset,
            engine: model.id
        ))
    }

    /// Summarize a transcribed meeting and write summary.md.
    @discardableResult
    public func summarize(
        meetingID: String,
        provider: LLMProvider = LLMSettings.current,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> MeetingSummary {
        guard let transcript = loadTranscript(meetingID: meetingID) else {
            throw TranscriptionError.audioFileMissing(store.paths(for: meetingID).transcriptJSON)
        }
        guard var metadata = store.load(id: meetingID) else {
            throw TranscriptionError.audioFileMissing(store.paths(for: meetingID).directory)
        }

        metadata.status = .summarizing
        try? store.save(metadata)

        do {
            let summarizer = Summarizer(provider: provider)
            let summary = try await summarizer.summarize(transcript: transcript, onProgress: onProgress)

            let paths = store.paths(for: meetingID)
            try summary.markdown.write(to: paths.summary, atomically: true, encoding: .utf8)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(summary).write(to: paths.summaryJSON, options: .atomic)

            // Names the model heard in the room become the transcript's speaker
            // labels, which is the whole point of asking for them: diarization
            // only ever produces "Speaker 2", and until now the only way to see
            // a real name was to type it in.
            if !summary.speakerNames.isEmpty {
                _ = try? applyNames(
                    resolveSpeakerIDs(for: summary.speakerNames, in: transcript),
                    meetingID: meetingID
                )
            }

            // The generated title becomes the meeting's name everywhere.
            metadata.title = summary.title
            metadata.status = .complete
            try? store.save(metadata)

            Log.llm.info("summarized \(meetingID, privacy: .public) via \(provider.name, privacy: .public)")
            return summary
        } catch {
            // A failed summary must not lose the transcript, which is the part
            // that actually took the meeting to produce.
            metadata.status = .complete
            try? store.save(metadata)
            throw error
        }
    }

    public func loadSummary(meetingID: String) -> MeetingSummary? {
        guard let data = try? Data(contentsOf: store.paths(for: meetingID).summaryJSON) else {
            return nil
        }
        return try? JSONDecoder().decode(MeetingSummary.self, from: data)
    }

    public func loadTranscript(meetingID: String) -> Transcript? {
        let url = store.paths(for: meetingID).transcriptJSON
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Transcript.self, from: data)
    }

    /// Renames a speaker everywhere and rewrites the Markdown export.
    public func rename(
        speakerID: String,
        to name: String,
        meetingID: String
    ) throws -> Transcript? {
        try applyNames([speakerID: name], meetingID: meetingID)
    }

    /// Which speakers the summary's names actually belong to, and which of those
    /// we are allowed to overwrite.
    ///
    /// The summary keys labels ("Speaker 2") because that is what the model was
    /// shown; the transcript keys ids ("speaker_1"). Two rules narrow the result:
    ///
    /// - A label that no longer reads as generated has been renamed by hand, and
    ///   a model's guess must not overwrite what someone deliberately typed.
    ///   Re-summarizing a meeting is a routine thing to do, and silently
    ///   reverting the user's correction every time would be maddening.
    /// - `"you"` is skipped outright. It is the person reading the summary, not
    ///   a voice to be identified.
    func resolveSpeakerIDs(
        for names: [String: String],
        in transcript: Transcript
    ) -> [String: String] {
        var byLabel: [String: String] = [:]
        for id in transcript.speakerIDs where id != TranscriptAssembler.localSpeakerID {
            let label = transcript.name(for: id)
            guard Self.isGeneratedName(label) else { continue }
            byLabel[label.lowercased()] = id
        }

        var resolved: [String: String] = [:]
        for (label, name) in names {
            guard let id = byLabel[label.trimmingCharacters(in: .whitespaces).lowercased()] else { continue }
            resolved[id] = name
        }
        return resolved
    }

    /// Whether a display name is still one `TranscriptAssembler` generated,
    /// rather than something a person chose.
    static func isGeneratedName(_ name: String) -> Bool {
        let parts = name.split(separator: " ")
        guard parts.count == 2, parts[0] == "Speaker" else { return false }
        return parts[1].allSatisfy(\.isNumber)
    }

    /// Applies a batch of speaker renames and rewrites both exports.
    @discardableResult
    func applyNames(_ names: [String: String], meetingID: String) throws -> Transcript? {
        guard !names.isEmpty else { return loadTranscript(meetingID: meetingID) }
        guard var transcript = loadTranscript(meetingID: meetingID) else { return nil }
        for (speakerID, name) in names {
            transcript.speakerNames[speakerID] = name
        }

        let paths = store.paths(for: meetingID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(transcript).write(to: paths.transcriptJSON, options: .atomic)

        // Renaming rewrites the whole Markdown file, so the screenshots have to
        // be re-merged here too or they would silently vanish from the export.
        let title = store.load(id: meetingID)?.displayTitle ?? "Meeting"
        try transcript
            .markdown(title: title, screenshots: screenshots.load(meetingID: meetingID))
            .write(to: paths.transcriptMarkdown, atomically: true, encoding: .utf8)
        return transcript
    }
}
