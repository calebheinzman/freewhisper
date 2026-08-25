import Foundation

public enum MeetingStatus: String, Codable, Sendable {
    case recording
    case awaitingTranscription
    case transcribing
    case summarizing
    case complete
    case failed
}

/// Everything about a meeting except the audio and the transcript, stored as
/// `meta.json` alongside them.
public struct MeetingMetadata: Codable, Sendable, Identifiable, Equatable {
    /// Directory name, e.g. `2026-08-25T07-15-03-slack-huddle`.
    public var id: String

    /// LLM-generated once summarization runs; until then a fallback built from
    /// the detected app and time.
    public var title: String?
    /// Display name of the app we detected, if this was an auto-detected call.
    public var detectedApp: String?
    public var meetingKind: String?

    public var startedAt: Date
    public var endedAt: Date?

    /// Wall-clock instants each stream actually began. The two capture paths
    /// start milliseconds apart, and this offset is what lets the transcript
    /// assembler line their timelines up.
    public var micStartedAt: Date?
    public var systemStartedAt: Date?

    public var hasMicAudio: Bool
    public var hasSystemAudio: Bool
    /// Non-nil when a stream was requested but failed; surfaced in the UI so a
    /// half-captured meeting is never mistaken for a complete one.
    public var micError: String?
    public var systemAudioError: String?

    public var status: MeetingStatus
    public var transcriptionEngine: String?

    public init(
        id: String,
        title: String? = nil,
        detectedApp: String? = nil,
        meetingKind: String? = nil,
        startedAt: Date,
        endedAt: Date? = nil,
        micStartedAt: Date? = nil,
        systemStartedAt: Date? = nil,
        hasMicAudio: Bool = false,
        hasSystemAudio: Bool = false,
        micError: String? = nil,
        systemAudioError: String? = nil,
        status: MeetingStatus = .recording,
        transcriptionEngine: String? = nil
    ) {
        self.id = id
        self.title = title
        self.detectedApp = detectedApp
        self.meetingKind = meetingKind
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.micStartedAt = micStartedAt
        self.systemStartedAt = systemStartedAt
        self.hasMicAudio = hasMicAudio
        self.hasSystemAudio = hasSystemAudio
        self.micError = micError
        self.systemAudioError = systemAudioError
        self.status = status
        self.transcriptionEngine = transcriptionEngine
    }

    public var duration: TimeInterval {
        guard let endedAt else { return Date().timeIntervalSince(startedAt) }
        return endedAt.timeIntervalSince(startedAt)
    }

    /// Offset of the system stream relative to the mic stream, in seconds.
    /// Positive means system audio started later, so its timestamps need
    /// shifting forward to sit on the mic's timeline.
    public var systemStreamOffset: TimeInterval {
        guard let micStartedAt, let systemStartedAt else { return 0 }
        return systemStartedAt.timeIntervalSince(micStartedAt)
    }

    /// The instant transcript timestamps count from.
    ///
    /// Not `startedAt`: the assembler puts every segment on the *mic* stream's
    /// clock, shifting system segments onto it by `systemStreamOffset`. Anything
    /// that has to line up with the transcript — a screenshot, a marker —
    /// measures from here, or it lands tens of milliseconds off at best and a
    /// whole permission prompt off at worst.
    public var timelineOrigin: Date { micStartedAt ?? systemStartedAt ?? startedAt }

    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let detectedApp { return "\(detectedApp) call" }
        return "Recording"
    }
}
