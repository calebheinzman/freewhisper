import Foundation
import Testing

@testable import FreeWhisperKit

@Suite("Summary parsing")
struct SummarizerParsingTests {
    @Test("parses a clean JSON response")
    func cleanJSON() {
        let summary = Summarizer.parse("""
        {"title":"Standup","summary":"We discussed the migration.",
         "keyPoints":["backend done"],"actionItems":["Dan: backfill by Thursday"],
         "tags":["payments"]}
        """)

        #expect(summary.title == "Standup")
        #expect(summary.keyPoints == ["backend done"])
        #expect(summary.actionItems == ["Dan: backfill by Thursday"])
        #expect(summary.tags == ["payments"])
    }

    /// Models wrap JSON in code fences and commentary no matter how firmly the
    /// prompt asks them not to.
    @Test("parses JSON wrapped in a code fence and prose")
    func fencedJSON() {
        let summary = Summarizer.parse("""
        Sure! Here is the summary:

        ```json
        {"title":"Standup","summary":"Short."}
        ```

        Let me know if you need anything else.
        """)

        #expect(summary.title == "Standup")
        #expect(summary.summary == "Short.")
    }

    @Test("handles nested braces without truncating")
    func nestedBraces() {
        let summary = Summarizer.parse("""
        {"title":"A","summary":"B","meta":{"nested":{"deep":1}},"tags":["x"]}
        """)
        #expect(summary.title == "A")
        #expect(summary.tags == ["x"])
    }

    @Test("braces inside strings do not end the object early")
    func bracesInStrings() {
        let summary = Summarizer.parse(#"{"title":"Use {braces} carefully","summary":"ok"}"#)
        #expect(summary.title == "Use {braces} carefully")
        #expect(summary.summary == "ok")
    }

    @Test("falls back to the raw text rather than failing outright")
    func unparseableResponse() {
        let summary = Summarizer.parse("I could not produce JSON, sorry.")
        #expect(summary.title == "Meeting")
        #expect(summary.summary.contains("could not produce JSON"))
    }

    /// The regression this guards: given a schema example like
    /// "who: what, by when", models emit objects with those as keys. The
    /// original parser accepted only strings and silently dropped every action
    /// item — the single most valuable part of the summary.
    @Test("action items returned as objects are flattened, not dropped")
    func objectShapedActionItems() {
        let summary = Summarizer.parse("""
        {"title":"T","summary":"S","actionItems":[
          {"who":"Dan","what they will do":"Backfill the records","by when if stated":"Thursday"},
          {"who":"Sam","what they will do":"Tell the support team"}
        ]}
        """)

        #expect(summary.actionItems.count == 2)
        #expect(summary.actionItems[0] == "Dan: Backfill the records (Thursday)")
        #expect(summary.actionItems[1] == "Sam: Tell the support team")
    }

    @Test("an unrecognised object shape is still rendered rather than lost")
    func unknownObjectShape() {
        let items = Summarizer.stringArray([["foo": "alpha", "bar": "beta"]])
        #expect(items.count == 1)
        #expect(items[0].contains("alpha"))
        #expect(items[0].contains("beta"))
    }

    @Test("a due date already present in the text is not repeated")
    func dueDateNotDuplicated() {
        let rendered = Summarizer.flatten([
            "who": "Dan",
            "task": "Backfill the records by Thursday",
            "due": "Thursday",
        ])
        #expect(rendered == "Dan: Backfill the records by Thursday")
    }

    @Test("missing fields degrade rather than throw")
    func missingFields() {
        let summary = Summarizer.parse(#"{"summary":"Only a summary."}"#)
        #expect(summary.title == "Meeting")
        #expect(summary.keyPoints.isEmpty)
        #expect(summary.actionItems.isEmpty)
    }
}

@Suite("Transcript chunking")
struct SummarizerChunkingTests {
    @Test("short text is a single chunk")
    func shortTextIsOneChunk() {
        #expect(Summarizer.chunk("Alice: hello", size: 1000).count == 1)
    }

    @Test("long text splits into several chunks under the limit")
    func longTextSplits() {
        let line = "Alice: " + String(repeating: "word ", count: 20)
        let text = Array(repeating: line, count: 200).joined(separator: "\n")

        let chunks = Summarizer.chunk(text, size: 2000)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 2000 })
    }

    /// Splitting mid-sentence would orphan half of someone's point across a
    /// chunk boundary, where neither section's summary can make sense of it.
    @Test("chunks break on speaker turns, never mid-line")
    func chunksBreakOnLines() {
        let lines = (1...100).map { "Speaker \($0 % 3): " + String(repeating: "x", count: 60) }
        let text = lines.joined(separator: "\n")

        for chunk in Summarizer.chunk(text, size: 500) {
            for line in chunk.split(separator: "\n") {
                #expect(lines.contains(String(line)))
            }
        }
    }

    @Test("no content is lost across the split")
    func chunkingPreservesContent() {
        let lines = (1...50).map { "Speaker A: line number \($0)" }
        let text = lines.joined(separator: "\n")

        let rejoined = Summarizer.chunk(text, size: 300).joined(separator: "\n")
        #expect(rejoined == text)
    }
}

@Suite("Provider configuration")
struct LLMProviderTests {
    @Test("the chat completions URL is built from the base URL")
    func endpointConstruction() {
        let provider = LLMProvider(name: "T", baseURL: "http://localhost:11434/v1", model: "m")
        #expect(provider.chatCompletionsURL?.absoluteString == "http://localhost:11434/v1/chat/completions")
    }

    @Test("a trailing slash in the base URL does not produce a double slash")
    func trailingSlashTolerated() {
        let provider = LLMProvider(name: "T", baseURL: "http://localhost:11434/v1/", model: "m")
        #expect(provider.chatCompletionsURL?.absoluteString == "http://localhost:11434/v1/chat/completions")
    }

    @Test("the default provider is local, so nothing leaves the Mac unasked")
    func defaultIsLocal() {
        #expect(LLMProvider.onDevice.isLocal)
        #expect(LLMProvider.onDevice.keychainAccount == nil)
        #expect(LLMProvider.ollama.isLocal)
        #expect(LLMProvider.ollama.keychainAccount == nil)
    }

    /// The default has to work on a fresh install with nothing else installed —
    /// that is the entire reason the on-device backend exists.
    @Test("the default provider needs no third-party server")
    func defaultNeedsNothingInstalled() {
        #expect(LLMProvider.presets.first == LLMProvider.onDevice)
        #expect(LLMProvider.onDevice.resolvedBackend == .onDevice)
    }

    @Test("presets cover local and cloud options")
    func presetsCoverBothKinds() {
        #expect(LLMProvider.presets.contains { $0.isLocal })
        #expect(LLMProvider.presets.contains { !$0.isLocal })
    }

    /// Existing users have a provider already encoded in UserDefaults with no
    /// `backend` key. If decoding that threw, every one of them would silently
    /// lose their configuration on upgrade.
    @Test("a provider saved before backends existed still decodes")
    func legacyProviderDecodes() throws {
        let legacy = Data("""
        {"name":"OpenAI","baseURL":"https://api.openai.com/v1","model":"gpt-4o-mini",
         "keychainAccount":"openai","isLocal":false}
        """.utf8)

        let provider = try JSONDecoder().decode(LLMProvider.self, from: legacy)
        #expect(provider.name == "OpenAI")
        #expect(provider.backend == nil)
        #expect(provider.resolvedBackend == .openAICompatible)
    }

    @Test("a provider round-trips through JSON with its backend intact")
    func backendSurvivesEncoding() throws {
        let encoded = try JSONEncoder().encode(LLMProvider.onDevice)
        let decoded = try JSONDecoder().decode(LLMProvider.self, from: encoded)
        #expect(decoded == LLMProvider.onDevice)
        #expect(decoded.resolvedBackend == .onDevice)
    }

    @Test("HTTP providers resolve to the HTTP client, on-device ones do not")
    func backendRouting() {
        #expect(ChatClient.make(for: LLMProvider.ollama) is OpenAICompatibleClient)
        #expect(!(ChatClient.make(for: LLMProvider.onDevice) is OpenAICompatibleClient))
    }

    @Test("a successful completion body is parsed")
    func parseCompletion() throws {
        let data = Data("""
        {"choices":[{"message":{"role":"assistant","content":"  hello  "}}]}
        """.utf8)
        #expect(try OpenAICompatibleClient.extractContent(from: data) == "hello")
    }

    @Test("an empty completion is an error, not an empty summary")
    func emptyCompletionThrows() {
        let data = Data(#"{"choices":[{"message":{"content":"   "}}]}"#.utf8)
        #expect(throws: (any Error).self) {
            try OpenAICompatibleClient.extractContent(from: data)
        }
    }

    @Test("a malformed body is an error")
    func malformedBodyThrows() {
        #expect(throws: (any Error).self) {
            try OpenAICompatibleClient.extractContent(from: Data("nonsense".utf8))
        }
    }
}

@Suite("Speaker naming")
struct SummarizerSpeakerNameTests {
    private func pipeline() -> TranscriptionPipeline {
        TranscriptionPipeline(store: MeetingStore(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-names-\(UUID().uuidString)", isDirectory: true)
        ))
    }

    private func transcript(names: [String: String]) -> Transcript {
        Transcript(
            segments: names.keys.sorted().map { id in
                TranscriptSegment(
                    start: 0, end: 1, text: "hi",
                    channel: id == TranscriptAssembler.localSpeakerID ? .microphone : .system,
                    speakerID: id,
                    speakerName: names[id] ?? id
                )
            },
            speakerNames: names,
            engine: "test"
        )
    }

    @Test("parses the speaker map")
    func parsesMap() {
        let summary = Summarizer.parse("""
        {"title":"Standup","summary":"x","speakerNames":{"Speaker 1":"Sarah","Speaker 2":"Dan"}}
        """)
        #expect(summary.speakerNames == ["Speaker 1": "Sarah", "Speaker 2": "Dan"])
    }

    @Test("a response with no speaker map yields an empty one")
    func missingMap() {
        #expect(Summarizer.parse(#"{"title":"A","summary":"B"}"#).speakerNames.isEmpty)
    }

    /// Told to stay silent about speakers it can't identify, a model will
    /// instead echo the label back or answer "Unknown". Both mean "I don't
    /// know", and neither is a rename.
    @Test("drops echoed labels and placeholder names")
    func dropsNonAnswers() {
        let summary = Summarizer.parse("""
        {"title":"A","summary":"B","speakerNames":
         {"Speaker 1":"Sarah","Speaker 2":"Speaker 2","Speaker 3":"Unknown","Speaker 4":"  "}}
        """)
        #expect(summary.speakerNames == ["Speaker 1": "Sarah"])
    }

    @Test("a non-object speaker map is ignored rather than crashing")
    func wrongShapeMap() {
        #expect(Summarizer.parse(#"{"title":"A","summary":"B","speakerNames":["Sarah"]}"#).speakerNames.isEmpty)
    }

    /// Every meeting summarized before this field existed has a summary.json
    /// without it. Failing to decode those would lose the user a summary.
    @Test("decodes a summary written before speakerNames existed")
    func decodesOldSummaries() throws {
        let old = Data("""
        {"actionItems":["Dan: backfill"],"keyPoints":["done"],"summary":"S","tags":["t"],"title":"T"}
        """.utf8)
        let summary = try JSONDecoder().decode(MeetingSummary.self, from: old)

        #expect(summary.title == "T")
        #expect(summary.actionItems == ["Dan: backfill"])
        #expect(summary.speakerNames.isEmpty)
    }

    @Test("a summary missing its title is corrupt, not old")
    func rejectsCorruptSummaries() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(MeetingSummary.self, from: Data(#"{"summary":"S"}"#.utf8))
        }
    }

    @Test("round-trips through JSON")
    func roundTrips() throws {
        let summary = MeetingSummary(title: "T", summary: "S", speakerNames: ["Speaker 1": "Sarah"])
        let decoded = try JSONDecoder().decode(
            MeetingSummary.self, from: JSONEncoder().encode(summary)
        )
        #expect(decoded == summary)
    }

    @Test("markdown lists who was there, in a stable order")
    func markdownSection() {
        let markdown = MeetingSummary(
            title: "T", summary: "S", speakerNames: ["Speaker 2": "Dan", "Speaker 1": "Sarah"]
        ).markdown

        #expect(markdown.contains("""
        ## Who was here
        - Sarah (Speaker 1)
        - Dan (Speaker 2)
        """))
    }

    @Test("no speakers named means no section")
    func markdownOmitsEmptySection() {
        #expect(!MeetingSummary(title: "T", summary: "S").markdown.contains("Who was here"))
    }

    // MARK: Resolving labels onto ids

    @Test("maps the label the model saw back onto the speaker id")
    func resolvesLabels() {
        let resolved = pipeline().resolveSpeakerIDs(
            for: ["Speaker 1": "Sarah", "Speaker 2": "Dan"],
            in: transcript(names: ["speaker_0": "Speaker 1", "speaker_1": "Speaker 2"])
        )
        #expect(resolved == ["speaker_0": "Sarah", "speaker_1": "Dan"])
    }

    /// Re-summarizing is routine. Reverting a correction the user typed every
    /// time it happened would be maddening.
    @Test("a name the user typed is never overwritten")
    func keepsUserNames() {
        let resolved = pipeline().resolveSpeakerIDs(
            for: ["Speaker 1": "Sarah", "Priya": "Dan"],
            in: transcript(names: ["speaker_0": "Speaker 1", "speaker_1": "Priya"])
        )
        #expect(resolved == ["speaker_0": "Sarah"])
    }

    @Test("the local speaker is left alone")
    func skipsYou() {
        let resolved = pipeline().resolveSpeakerIDs(
            for: ["You": "Caleb", "Speaker 1": "Sarah"],
            in: transcript(names: ["you": "You", "speaker_0": "Speaker 1"])
        )
        #expect(resolved == ["speaker_0": "Sarah"])
    }

    @Test("a label for a speaker who isn't in the transcript is dropped")
    func ignoresUnknownLabels() {
        let resolved = pipeline().resolveSpeakerIDs(
            for: ["Speaker 7": "Nobody"],
            in: transcript(names: ["speaker_0": "Speaker 1"])
        )
        #expect(resolved.isEmpty)
    }

    @Test("only generated labels count as unclaimed")
    func generatedNames() {
        #expect(TranscriptionPipeline.isGeneratedName("Speaker 1"))
        #expect(TranscriptionPipeline.isGeneratedName("Speaker 12"))
        #expect(!TranscriptionPipeline.isGeneratedName("Speaker Sarah"))
        #expect(!TranscriptionPipeline.isGeneratedName("You"))
        #expect(!TranscriptionPipeline.isGeneratedName("Sarah"))
    }
}
