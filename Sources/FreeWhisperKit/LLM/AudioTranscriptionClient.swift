import Foundation

/// Minimal client for the OpenAI `/v1/audio/transcriptions` shape.
///
/// Sibling of ``OpenAICompatibleClient`` and deliberately shares its error
/// type: from the user's point of view "the provider returned 401" is the same
/// problem whether they were summarizing or transcribing, and two parallel
/// error enums would only mean writing the same messages twice.
public struct AudioTranscriptionClient: Sendable {
    private let provider: LLMProvider
    private let session: URLSession

    public init(provider: LLMProvider, session: URLSession = EgressSession.shared) {
        self.provider = provider
        self.session = session
    }

    /// Transcribes one file, returning segments timed from the start of *that
    /// file* — the caller adds the chunk offset.
    public func transcribe(url: URL) async throws -> [RawSegment] {
        let data = try Data(contentsOf: url)
        let name = url.lastPathComponent

        do {
            return try await send(data, filename: name, verbose: true)
        } catch OpenAICompatibleClient.ClientError.http(let status, let body) where
            status == 400 && Self.rejectsVerboseJSON(body)
        {
            // gpt-4o-transcribe and friends only speak `json`, which costs us
            // segment timings. Retrying is better than failing, but the caller
            // gets one segment spanning the clip rather than a timed
            // transcript, so say so rather than degrading quietly.
            Log.transcription.notice(
                "\(provider.model, privacy: .public) rejected verbose_json; retrying without timings"
            )
            return try await send(data, filename: name, verbose: false, duration: AudioLoader.duration(of: url))
        }
    }

    /// Cheap liveness check for the settings pane.
    ///
    /// Posts a fraction of a second of silence. There is no reliable
    /// `GET /models` across these endpoints, and a real round trip is the only
    /// thing that actually proves the key, the URL and the model name all work.
    public func testConnection() async throws {
        let silence = [Float](repeating: 0, count: Int(AudioFormats.sampleRate * 0.3))
        _ = try await send(Self.wav(silence), filename: "test.wav", verbose: false, duration: 0.3)
    }

    // MARK: Request

    private func send(
        _ audio: Data,
        filename: String,
        verbose: Bool,
        duration: TimeInterval = 0
    ) async throws -> [RawSegment] {
        guard let url = provider.audioTranscriptionsURL else {
            throw OpenAICompatibleClient.ClientError.invalidURL(provider.baseURL)
        }

        let boundary = "fw-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.body(
            boundary: boundary,
            audio: audio,
            filename: filename,
            fields: [
                "model": provider.model,
                "response_format": verbose ? "verbose_json" : "json",
                "temperature": "0",
            ]
        )
        // Uploading a 24 MB chunk on a slow connection and then waiting for it
        // to be transcribed comfortably outlasts the 60s default.
        request.timeoutInterval = 300

        if let key = provider.apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        } else if provider.keychainAccount != nil, !provider.isLocal {
            throw OpenAICompatibleClient.ClientError.missingAPIKey(provider.name)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if provider.isLocal {
                throw OpenAICompatibleClient.ClientError.cannotReachLocalServer(provider.name)
            }
            throw error
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw OpenAICompatibleClient.ClientError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        return try Self.segments(from: data, fallbackDuration: duration)
    }

    static func body(
        boundary: String,
        audio: Data,
        filename: String,
        fields: [String: String]
    ) -> Data {
        var body = Data()
        func append(_ string: String) {
            body.append(Data(string.utf8))
        }

        // Sorted so the body is deterministic, which is what makes it testable.
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) where !value.isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(audio)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    static func segments(from data: Data, fallbackDuration: TimeInterval) throws -> [RawSegment] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenAICompatibleClient.ClientError.emptyResponse
        }

        if let raw = json["segments"] as? [[String: Any]] {
            let segments = raw.compactMap { segment -> RawSegment? in
                guard let text = (segment["text"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    text.containsSpeech
                else { return nil }
                return RawSegment(
                    start: segment["start"] as? TimeInterval ?? 0,
                    end: segment["end"] as? TimeInterval ?? 0,
                    text: text
                )
            }
            if !segments.isEmpty { return segments }
        }

        // `response_format=json`, or a verbose response that carried no
        // segments: one span covering the whole clip is all the timing
        // information that exists.
        let text = (json["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard text.containsSpeech else { return [] }
        return [RawSegment(start: 0, end: fallbackDuration, text: text)]
    }

    static func rejectsVerboseJSON(_ body: String) -> Bool {
        let lowered = body.lowercased()
        return lowered.contains("verbose_json") || lowered.contains("response_format")
    }

    /// Builds an in-memory 16 kHz mono 16-bit WAV. Used only by
    /// ``testConnection()`` — everything else uploads a file we recorded.
    static func wav(_ samples: [Float]) -> Data {
        let rate = UInt32(AudioFormats.sampleRate)
        let payload = samples.count * 2
        var data = Data()

        func le<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(Data("RIFF".utf8))
        le(UInt32(36 + payload))
        data.append(Data("WAVEfmt ".utf8))
        le(UInt32(16))            // PCM header size
        le(UInt16(1))             // format: PCM
        le(UInt16(1))             // channels
        le(rate)
        le(rate * 2)              // byte rate
        le(UInt16(2))             // block align
        le(UInt16(16))            // bits per sample
        data.append(Data("data".utf8))
        le(UInt32(payload))

        for sample in samples {
            le(Int16(max(-1, min(1, sample)) * Float(Int16.max)))
        }
        return data
    }
}
