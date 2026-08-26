import Foundation

/// Whether to ask the user about a detected call, and for how long.
///
/// Pure, like `MeetingDetector`: no panel, no timer, no clock of its own. The
/// AppKit side owns the window and the run loop; every branch that could be
/// wrong lives here, where a test can reach it.
///
/// Nothing in this type can decide to record. The only outcomes are "ask" and
/// "don't ask" — a question nobody answered is not a yes.
public enum MeetingPromptPolicy {
    public enum IgnoreReason: String, Sendable, Equatable {
        case alreadyRecording
        case declined
        case alreadyAsking
    }

    public enum Decision: Sendable, Equatable {
        /// Show the prompt, and take it away after `seconds` if nobody answers.
        case ask(seconds: Int)
        /// Show the prompt and leave it until it is answered.
        case askUntilAnswered
        case ignore(IgnoreReason)
    }

    /// - Parameters:
    ///   - countdownSeconds: the user's setting. 0 means wait for an answer.
    ///   - isRecordingOrStarting: a call already being recorded is not a call to
    ///     ask about.
    ///   - declinedKey: the call the user last said "not now" to.
    ///   - askingAboutKey: the call a prompt is already on screen for.
    public static func decide(
        meetingKey: String,
        countdownSeconds: Int,
        isRecordingOrStarting: Bool,
        declinedKey: String?,
        askingAboutKey: String?
    ) -> Decision {
        if isRecordingOrStarting { return .ignore(.alreadyRecording) }
        if declinedKey == meetingKey { return .ignore(.declined) }
        // A second call turning up mid-question: the first one wins. Two panels,
        // or one that silently changes what it is asking about, is worse than
        // missing a call the user can still start by hand.
        if let askingAboutKey, askingAboutKey != meetingKey { return .ignore(.alreadyAsking) }
        // Defaults can hold anything an older build or a hand-edited plist put
        // there, and a negative timeout would take the panel away before it drew.
        guard countdownSeconds > 0 else { return .askUntilAnswered }
        return .ask(seconds: countdownSeconds)
    }

    /// Rounded up, so the label reads "1s" for the whole final second rather
    /// than showing "0s" next to a panel that is still on screen.
    public static func remainingSeconds(until deadline: Date, now: Date = Date()) -> Int {
        max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
    }
}
