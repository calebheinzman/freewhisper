import Foundation

/// Which capture stream a piece of speech came from.
public enum TranscriptChannel: String, Codable, Sendable {
    /// The microphone — always the local user.
    case microphone
    /// System audio — everyone else on the call.
    case system
}

/// A span of speech with a start time, in seconds from the meeting start.
public struct RawSegment: Sendable, Equatable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// A stretch of audio attributed to one speaker by a diarizer.
public struct SpeakerTurn: Sendable, Equatable {
    public var start: TimeInterval
    public var end: TimeInterval
    /// Engine-local speaker identifier, e.g. `"speaker_1"`.
    public var speakerID: String

    public init(start: TimeInterval, end: TimeInterval, speakerID: String) {
        self.start = start
        self.end = end
        self.speakerID = speakerID
    }

    func overlap(with segment: RawSegment) -> TimeInterval {
        max(0, min(end, segment.end) - max(start, segment.start))
    }
}

/// One line of the finished transcript.
public struct TranscriptSegment: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var channel: TranscriptChannel
    /// Stable key used to rename a speaker across the whole transcript.
    /// `"you"` for the microphone channel, `"speaker_N"` otherwise.
    public var speakerID: String
    /// What to show. Defaults to a generated name until the user renames it.
    public var speakerName: String

    public init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        channel: TranscriptChannel,
        speakerID: String,
        speakerName: String
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.channel = channel
        self.speakerID = speakerID
        self.speakerName = speakerName
    }
}

public struct Transcript: Codable, Sendable, Equatable {
    public var segments: [TranscriptSegment]
    /// speakerID -> display name, so a rename applies everywhere at once.
    public var speakerNames: [String: String]
    public var engine: String
    public var generatedAt: Date

    public init(
        segments: [TranscriptSegment],
        speakerNames: [String: String] = [:],
        engine: String,
        generatedAt: Date = Date()
    ) {
        self.segments = segments
        self.speakerNames = speakerNames
        self.engine = engine
        self.generatedAt = generatedAt
    }

    public var isEmpty: Bool { segments.isEmpty }

    public func name(for speakerID: String) -> String {
        speakerNames[speakerID] ?? speakerID
    }

    /// Distinct speakers in the order they first spoke.
    public var speakerIDs: [String] {
        var seen = Set<String>()
        return segments.compactMap { segment in
            seen.insert(segment.speakerID).inserted ? segment.speakerID : nil
        }
    }

    public var plainText: String {
        segments.map { "\(name(for: $0.speakerID)): \($0.text)" }.joined(separator: "\n")
    }

    /// The transcript as Markdown, with any screenshots taken during the meeting
    /// linked in at the point they were captured.
    ///
    /// Image paths stay relative to the meeting directory, so the exported file
    /// renders wherever the folder is moved to.
    public func markdown(title: String, screenshots: [MeetingScreenshot] = []) -> String {
        var lines = ["# \(title)", ""]

        for entry in TranscriptTimeline.entries(transcript: self, screenshots: screenshots) {
            lines.append("")
            switch entry {
            case .turn(let turn):
                lines.append("**\(name(for: turn.speakerID))** _(\(Self.timestamp(turn.start)))_")
                lines.append(contentsOf: turn.texts)
            case .screenshot(let screenshot):
                for image in screenshot.images {
                    lines.append("![Screenshot at \(Self.timestamp(screenshot.offset))](\(image.relativePath))")
                }
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

extension String {
    /// Whether this looks like something a person actually said.
    ///
    /// Both ASR engines emit punctuation-only fragments over silence — a bare
    /// ".", "...", or a dash — which are noise rather than speech. Requiring at
    /// least one letter or digit filters them without touching real text.
    var containsSpeech: Bool {
        rangeOfCharacter(from: .alphanumerics) != nil
    }
}
