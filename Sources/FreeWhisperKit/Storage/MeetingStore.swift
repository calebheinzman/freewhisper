import Foundation

/// One of the two capture streams.
public enum AudioStream: String, Sendable, CaseIterable {
    /// The microphone — always the local user.
    case microphone = "mic"
    /// Everything the Mac played — everyone else on the call.
    case system

    public var displayName: String {
        switch self {
        case .microphone: "Microphone"
        case .system: "System audio"
        }
    }
}

/// A piece of one capture stream, and where it sits on that stream's clock.
public struct AudioSegment: Sendable, Equatable {
    public let url: URL
    /// Seconds from the moment the stream first opened. Non-zero only for a
    /// piece written after capture was restarted mid-meeting.
    public let offset: TimeInterval

    public init(url: URL, offset: TimeInterval) {
        self.url = url
        self.offset = offset
    }
}

/// Filesystem layout for one meeting.
public struct MeetingPaths: Sendable {
    public let directory: URL

    public var micAudio: URL { audio(.microphone) }
    public var systemAudio: URL { audio(.system) }
    public var metadata: URL { directory.appendingPathComponent("meta.json") }
    public var transcriptJSON: URL { directory.appendingPathComponent("transcript.json") }
    public var transcriptMarkdown: URL { directory.appendingPathComponent("transcript.md") }
    public var summary: URL { directory.appendingPathComponent("summary.md") }
    /// The same summary structured, for the UI. summary.md stays the
    /// human-facing artifact users can read, grep and share.
    public var summaryJSON: URL { directory.appendingPathComponent("summary.json") }

    public var screenshotsDirectory: URL {
        directory.appendingPathComponent("screenshots", isDirectory: true)
    }

    /// Screenshots live in their own manifest rather than in meta.json, which
    /// `RecordingSession` is rewriting throughout the call — two writers on one
    /// file would lose whichever wrote first.
    public var screenshotsManifest: URL { directory.appendingPathComponent("screenshots.json") }

    public init(directory: URL) {
        self.directory = directory
    }

    // MARK: Audio

    /// Where a stream starts recording.
    public func audio(_ stream: AudioStream) -> URL {
        directory.appendingPathComponent("\(stream.rawValue).wav")
    }

    /// A free path for a stream to continue into after it has been restarted.
    ///
    /// The number is the offset in seconds from the moment that stream first
    /// opened, which is what puts the piece back on the meeting's timeline. Two
    /// restarts inside one second would name the same file and the second would
    /// truncate the first, so step forward until the name is free — a second of
    /// drift on a piece boundary is nothing next to losing the piece.
    public func audioSegment(_ stream: AudioStream, restartedAt offset: TimeInterval) -> URL {
        var seconds = max(1, Int(offset))
        var url = directory.appendingPathComponent("\(stream.rawValue)-\(seconds).wav")
        while FileManager.default.fileExists(atPath: url.path) {
            seconds += 1
            url = directory.appendingPathComponent("\(stream.rawValue)-\(seconds).wav")
        }
        return url
    }

    /// Every piece of one stream that exists on disk, earliest first.
    ///
    /// Usually one. A stream that was restarted mid-meeting — a headset
    /// connecting, a device going away — has its remainder in numbered siblings,
    /// and all of them are part of the recording.
    public func segments(of stream: AudioStream) -> [AudioSegment] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .compactMap { name in
                Self.offset(ofSegment: name, in: stream).map {
                    AudioSegment(url: directory.appendingPathComponent(name), offset: $0)
                }
            }
            .sorted { $0.offset < $1.offset }
    }

    /// `mic.wav` → 0, `system-2622.wav` → 2622, anything else → nil.
    static func offset(ofSegment name: String, in stream: AudioStream) -> TimeInterval? {
        guard name.hasSuffix(".wav") else { return nil }

        let stem = name.dropLast(4)
        if stem == stream.rawValue { return 0 }

        let prefix = "\(stream.rawValue)-"
        guard stem.hasPrefix(prefix) else { return nil }

        let seconds = stem.dropFirst(prefix.count)
        guard !seconds.isEmpty, seconds.allSatisfy(\.isNumber) else { return nil }
        return TimeInterval(seconds)
    }
}

/// Plain files on disk, no database.
///
/// A meeting is a directory of WAVs, a `meta.json` and Markdown. That means the
/// user can read, grep, back up and — importantly for a tool that records their
/// conversations — delete their data without going through us.
public final class MeetingStore: @unchecked Sendable {
    public static let shared = MeetingStore()

    public let root: URL
    private let fileManager = FileManager.default

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.root = support
                .appendingPathComponent("FreeWhisper", isDirectory: true)
                .appendingPathComponent("Meetings", isDirectory: true)
        }
        // 0700 rather than the default 0755. Recordings of other people are
        // about as sensitive as this app gets, and while ~/Library/Application
        // Support happens to be owner-only today, that is not a property to rely
        // on — permissions travel when a tree is copied, rsynced or restored.
        try? fileManager.createDirectory(
            at: self.root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    // MARK: Creating

    public func createMeeting(
        startedAt: Date = Date(),
        detectedApp: String? = nil,
        meetingKind: String? = nil
    ) throws -> (MeetingMetadata, MeetingPaths) {
        let id = Self.identifier(for: startedAt, detectedApp: detectedApp)
        let directory = root.appendingPathComponent(id, isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let metadata = MeetingMetadata(
            id: id,
            detectedApp: detectedApp,
            meetingKind: meetingKind,
            startedAt: startedAt
        )
        let paths = MeetingPaths(directory: directory)
        try save(metadata)
        return (metadata, paths)
    }

    /// `2026-08-25T07-15-03-slack` — sorts chronologically as a plain string,
    /// which is why the timestamp leads and uses dashes rather than colons.
    static func identifier(for date: Date, detectedApp: String?) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current

        var id = formatter.string(from: date)
        if let slug = detectedApp?.slugified(), !slug.isEmpty {
            id += "-\(slug)"
        }
        return id
    }

    // MARK: Reading and writing

    public func paths(for id: String) -> MeetingPaths {
        MeetingPaths(directory: root.appendingPathComponent(Self.safeID(id), isDirectory: true))
    }

    /// Ids we generate are a timestamp plus a slug, so they reduce to
    /// `[a-z0-9-]` — but an id can also arrive from the `id` field *inside* a
    /// `meta.json`, which is a file on disk that we do not control. A value like
    /// `../../../../tmp/x` would otherwise escape the meetings directory, and
    /// `delete(id:)` hands the result straight to `removeItem`.
    static func safeID(_ id: String) -> String {
        let cleaned = id.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: "..", with: "-")
        return cleaned.hasPrefix(".") ? String(cleaned.dropFirst()) : cleaned
    }

    /// Fractional seconds matter: the gap between when the mic stream and the
    /// system stream actually opened is tens of milliseconds, and that offset is
    /// what aligns the two transcripts. Plain `.iso8601` truncates it away.
    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(dateFormatter.string(from: date))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = dateFormatter.date(from: text) ?? fallbackFormatter.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unrecognised date: \(text)"
                ))
            }
            return date
        }
        return decoder
    }

    /// Reads meetings written before fractional seconds were stored.
    private static let fallbackFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public func save(_ metadata: MeetingMetadata) throws {
        let data = try Self.makeEncoder().encode(metadata)
        try data.write(to: paths(for: metadata.id).metadata, options: .atomic)
    }

    public func load(id: String) -> MeetingMetadata? {
        let url = paths(for: id).metadata
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.makeDecoder().decode(MeetingMetadata.self, from: data)
    }

    /// Newest first.
    public func list() -> [MeetingMetadata] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .compactMap { load(id: $0.lastPathComponent) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// Repairs meetings left mid-flight by a crash or a force-quit.
    ///
    /// A meeting stuck at `.recording` is certainly not recording any more —
    /// no process survives to write to it — and leaving the status alone means
    /// the UI claims a recording is in progress forever.
    public func repairInterruptedMeetings() {
        for var meeting in list() {
            switch meeting.status {
            case .recording:
                meeting.status = .awaitingTranscription
                meeting.endedAt = meeting.endedAt ?? Date()
                if meeting.micError == nil, meeting.systemAudioError == nil {
                    meeting.micError = "Recording was interrupted before it finished."
                }
            case .transcribing, .summarizing:
                meeting.status = .awaitingTranscription
            default:
                continue
            }
            try? save(meeting)
            Log.storage.notice("repaired interrupted meeting \(meeting.id, privacy: .public)")
        }
    }

    /// Removes the audio too — deleting a meeting has to actually delete it.
    public func delete(id: String) throws {
        try fileManager.removeItem(at: paths(for: id).directory)
        Log.storage.info("deleted meeting \(id, privacy: .public)")
    }

    public func totalBytesOnDisk() -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
        return total
    }
}

extension String {
    /// Lowercase, alphanumerics and dashes only — safe for a directory name.
    func slugified() -> String {
        let allowed = CharacterSet.alphanumerics
        let scalars = lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }
}
