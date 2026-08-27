import Foundation

/// Measured accuracy and speed for the models in ``ModelCatalog``.
///
/// Every model in the picker used to be described by a sentence someone wrote
/// by hand — "strongest on accents", "roughly twice the speed" — inherited from
/// upstream marketing and never checked. Those claims are now measured, by
/// `eval/`, against public corpora with published ground truth, and this is how
/// the result reaches the person choosing.
///
/// Deliberately a small, dumb reader. The numbers are produced by an offline
/// harness that takes hours and needs Python; nothing here recomputes anything,
/// and a missing or malformed file means the picker shows what it always showed
/// rather than showing nothing.
public enum ModelScorecard {
    public struct Entry: Codable, Sendable, Equatable {
        /// 0-1, higher is better. What "accurate" means differs by role — word
        /// error for dictation, words-and-speakers for meetings, a judged rubric
        /// for summaries — so this is only ever comparable *within* a list.
        public let accuracy: Double
        /// Realtime factor for speech models, seconds per meeting for
        /// summarizers. Which one is in `speedUnit`.
        public let speed: Double?
        public let speedUnit: String?
        public let track: String?
    }

    /// The three buckets the picker shows instead of the raw score.
    ///
    /// A number invites comparisons the measurement cannot carry: 0.94 against
    /// 0.93 is one corpus and a rounding away from reversing, and nobody
    /// choosing a dictation model needs to know which side of that they are on.
    /// Three buckets say the thing that survives a re-run — this one is fine,
    /// this one is a compromise, this one is broken.
    public enum Quality: String, Sendable, CaseIterable {
        case good = "Good"
        case medium = "Medium"
        case poor = "Poor"
    }

    /// Which job a score is about.
    ///
    /// The same model is offered for two different jobs and is not equally good
    /// at both, so a single badge per model would be wrong in one of the two
    /// places it appears.
    public enum Role: String, Sendable {
        case dictation = "asr"
        case meeting
        case summary = "summarize"
    }

    /// Boundaries, per job, because the scores are not on the same scale.
    ///
    /// Dictation is `1 − WER`: one word in ten wrong is a good transcript, one
    /// in four is not usable, and a normalized word error rate genuinely can
    /// approach zero.
    ///
    /// Meetings are `1 − tcpWER`, which scores words *and* who said them, and
    /// which nothing reaches 0.9 on — the published state of the art on this
    /// kind of audio is around 0.69, and the best model here manages 0.61.
    /// Judging that against the dictation boundaries would label every option
    /// "Poor", which tells the user nothing except that the scale is wrong.
    ///
    /// The 0.60 bar below was set when the best model managed 0.50 and nothing
    /// cleared it. Word-level speaker attribution moved the Parakeet rows past
    /// it without the bar moving, which is the right way round: the boundary
    /// was drawn at what a genuinely usable meeting transcript looks like, not
    /// at whatever the field happened to be scoring that week.
    ///
    /// Summaries are a judged rubric and sit between the two.
    public static func quality(for accuracy: Double, role: Role) -> Quality {
        // Set where the measurements actually land, not at round numbers.
        //
        // Dictation averages clean, accented and spontaneous speech, and the
        // last of those is short disfluent non-native turns that nothing
        // transcribes cleanly — every working model here scores 0.57 to 0.76 on
        // it. A 0.90 bar is unreachable on that mix and grades the whole list
        // "Medium", which is not a grade, it is a broken scale. 0.85 is where
        // the one model that is meaningfully better at spontaneous speech
        // separates from the three that cluster behind it.
        let (good, medium): (Double, Double) = switch role {
        case .dictation: (0.85, 0.70)
        case .meeting: (0.60, 0.42)
        case .summary: (0.70, 0.50)
        }
        switch accuracy {
        case good...: return .good
        case medium..<good: return .medium
        default: return .poor
        }
    }

    /// The word to show for a model in a given role, or nil when unmeasured.
    public static func qualityLabel(for modelID: String, role: Role) -> String? {
        entry(for: modelID, role: role).map { quality(for: $0.accuracy, role: role).rawValue }
    }

    /// Model id -> role -> what was measured. Nested because a speech model is
    /// scored twice, once for each job it is offered for.
    struct File: Codable {
        let measuredOn: String
        let generatedAt: String
        let models: [String: [String: Entry]]
    }

    /// The machine the timings came from. Shown beside them, because a realtime
    /// factor without a machine attached is not a fact about anything.
    public static var measuredOn: String? { loaded?.measuredOn }
    public static var generatedAt: String? { loaded?.generatedAt }
    public static var isAvailable: Bool { loaded != nil }

    public static func entry(for modelID: String, role: Role) -> Entry? {
        loaded?.models[modelID]?[role.rawValue]
    }

    /// Speed as something to read, or nil when there is nothing to say.
    public static func speedLabel(for modelID: String, role: Role) -> String? {
        guard let entry = entry(for: modelID, role: role) else { return nil }
        return speedLabel(speed: entry.speed, unit: entry.speedUnit)
    }

    static func speedLabel(speed: Double?, unit: String?) -> String? {
        guard let speed, speed > 0 else { return nil }
        switch unit {
        case "realtimeFactor":
            // Rounded hard on purpose. The difference between 38× and 41× is
            // run-to-run noise, and printing it implies a precision the
            // measurement does not have.
            return speed >= 10
                ? "\(Int(speed.rounded()))× realtime"
                : String(format: "%.1f× realtime", speed)
        case "secondsPerMeeting":
            return speed < 60
                ? "\(Int(speed.rounded()))s per meeting"
                : String(format: "%.0f min per meeting", speed / 60)
        default:
            return nil
        }
    }

    // MARK: Loading

    private static let loaded: File? = load()

    private static func load() -> File? {
        guard let url = Bundle.module.url(forResource: "scorecard", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else {
            Log.transcription.notice("no model scorecard bundled")
            return nil
        }
        return file
    }
}
