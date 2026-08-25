import Foundation

public struct MeetingSummary: Codable, Sendable, Equatable {
    public var title: String
    public var summary: String
    public var keyPoints: [String]
    public var actionItems: [String]
    public var tags: [String]

    public init(
        title: String,
        summary: String,
        keyPoints: [String] = [],
        actionItems: [String] = [],
        tags: [String] = []
    ) {
        self.title = title
        self.summary = summary
        self.keyPoints = keyPoints
        self.actionItems = actionItems
        self.tags = tags
    }

    public var markdown: String {
        var lines = ["# \(title)", "", summary, ""]

        if !keyPoints.isEmpty {
            lines.append("## Key points")
            lines.append(contentsOf: keyPoints.map { "- \($0)" })
            lines.append("")
        }
        if !actionItems.isEmpty {
            lines.append("## Action items")
            lines.append(contentsOf: actionItems.map { "- [ ] \($0)" })
            lines.append("")
        }
        if !tags.isEmpty {
            lines.append("**Tags:** " + tags.map { "`\($0)`" }.joined(separator: " "))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

/// Turns a transcript into a title, summary, key points and action items.
public struct Summarizer: Sendable {
    /// Characters per chunk. Conservative enough that an 8k-context local model
    /// can hold a chunk plus its instructions, which is the constraint that
    /// actually binds — cloud models have room to spare.
    static let chunkSize = 6_000
    /// Above this, summarize in chunks and then combine.
    static let mapReduceThreshold = 8_000

    private let client: any ChatCompleting
    private let providerName: String

    public init(provider: LLMProvider) {
        self.client = ChatClient.make(for: provider)
        self.providerName = provider.name
    }

    public func summarize(
        transcript: Transcript,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> MeetingSummary {
        let text = transcript.plainText
        guard !text.isEmpty else {
            throw OpenAICompatibleClient.ClientError.emptyResponse
        }

        let condensed: String
        if text.count > Self.mapReduceThreshold {
            onProgress?("Summarizing in sections…")
            condensed = try await mapReduce(text, onProgress: onProgress)
        } else {
            condensed = text
        }

        onProgress?("Writing the summary…")
        let response = try await client.complete(
            messages: [
                .system(Self.systemPrompt),
                .user(Self.finalPrompt(transcript: condensed)),
            ],
            temperature: 0.2,
            maxTokens: nil
        )
        return Self.parse(response)
    }

    /// Summarize each chunk, then summarize the summaries. Sequential rather
    /// than concurrent because the default provider is a local model, where
    /// parallel requests just queue and compete for the same GPU.
    private func mapReduce(
        _ text: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> String {
        let chunks = Self.chunk(text, size: Self.chunkSize)
        var partials: [String] = []

        for (index, chunk) in chunks.enumerated() {
            onProgress?("Summarizing section \(index + 1) of \(chunks.count)…")
            let partial = try await client.complete(
                messages: [
                    .system("You condense meeting transcripts. Keep names, decisions, numbers and commitments. Drop small talk."),
                    .user("Condense this section of a meeting transcript into dense notes.\n\n\(chunk)"),
                ],
                temperature: 0.1,
                maxTokens: nil
            )
            partials.append(partial)
        }
        return partials.joined(separator: "\n\n")
    }

    /// Split on speaker turns rather than mid-sentence, so a chunk boundary
    /// never orphans half of someone's point.
    static func chunk(_ text: String, size: Int) -> [String] {
        guard text.count > size else { return [text] }

        var chunks: [String] = []
        var current = ""

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + line.count + 1 > size, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // MARK: Prompting

    static let systemPrompt = """
    You summarize meeting transcripts. The transcripts come from automatic \
    speech recognition, so expect occasional mis-heard words and speakers \
    labelled only as "Speaker 1"; infer meaning from context rather than \
    quoting errors, and prefer real names when they are said aloud.

    Respond with JSON only, no code fence, in exactly this shape:
    {
      "title": "short specific title, max 8 words",
      "summary": "one paragraph, 2-4 sentences",
      "keyPoints": ["..."],
      "actionItems": ["one plain sentence naming who will do what, and by when if stated"],
      "tags": ["lowercase-topic"]
    }

    Every array element is a plain string, never a nested object.

    An action item is anything someone said they would do, agreed to do, or \
    committed to a date for, including commitments phrased casually. Deadlines \
    and target dates the group settled on count too. Take them only from the \
    transcript: do not invent commitments nobody made, and never copy the \
    wording of these instructions into your answer.
    """

    static func finalPrompt(transcript: String) -> String {
        """
        Summarize this meeting.

        \(transcript)
        """
    }

    // MARK: Parsing

    /// Models wrap JSON in prose and code fences no matter how firmly asked not
    /// to, so pull out the outermost object rather than trusting the shape.
    static func parse(_ response: String) -> MeetingSummary {
        guard let json = extractJSONObject(from: response),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // Better to hand back the model's prose than to fail outright.
            return MeetingSummary(title: "Meeting", summary: response)
        }

        return MeetingSummary(
            title: (object["title"] as? String) ?? "Meeting",
            summary: (object["summary"] as? String) ?? "",
            keyPoints: stringArray(object["keyPoints"]),
            actionItems: stringArray(object["actionItems"]),
            tags: stringArray(object["tags"])
        )
    }

    static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var escaped = false

        for index in text[start...].indices {
            let character = text[index]
            if escaped {
                escaped = false
                continue
            }
            switch character {
            case "\\" where inString: escaped = true
            case "\"": inString.toggle()
            case "{" where !inString: depth += 1
            case "}" where !inString:
                depth -= 1
                if depth == 0 { return String(text[start...index]) }
            default: break
            }
        }
        return nil
    }

    /// Coerce a JSON array into strings.
    ///
    /// Models routinely return objects where the schema asked for strings —
    /// given `["who: what, by when"]` as an example, they will happily emit
    /// `{"who": …, "what": …}` instead. Silently dropping those loses exactly
    /// the action items the summary is for, so flatten them rather than
    /// insisting the model behave.
    static func stringArray(_ value: Any?) -> [String] {
        guard let array = value as? [Any] else { return [] }

        return array.compactMap { element -> String? in
            if let text = element as? String { return text }
            if let object = element as? [String: Any] { return flatten(object) }
            return nil
        }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }

    /// Render `{"who": "Alice", "task": "ship it", "due": "Thursday"}` as
    /// `"Alice: ship it (Thursday)"`.
    static func flatten(_ object: [String: Any]) -> String? {
        func value(matching candidates: [String]) -> String? {
            for (key, value) in object {
                let normalized = key.lowercased()
                guard candidates.contains(where: { normalized.contains($0) }) else { continue }
                if let text = value as? String, !text.isEmpty { return text }
            }
            return nil
        }

        let owner = value(matching: ["who", "owner", "assignee", "person"])
        let task = value(matching: ["what", "task", "action", "item", "description"])
        let due = value(matching: ["when", "due", "deadline", "by", "date"])

        var parts: [String] = []
        if let owner { parts.append(owner) }
        if let task { parts.append(task) }

        var rendered = parts.count == 2 ? "\(parts[0]): \(parts[1])" : parts.first ?? ""
        if rendered.isEmpty {
            // Unrecognised shape — join whatever strings it has rather than
            // dropping the item entirely.
            rendered = object.values.compactMap { $0 as? String }.joined(separator: " — ")
        }
        guard !rendered.isEmpty else { return nil }

        if let due, !rendered.localizedCaseInsensitiveContains(due) {
            rendered += " (\(due))"
        }
        return rendered
    }
}
