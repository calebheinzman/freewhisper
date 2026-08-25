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

    struct File: Codable {
        let measuredOn: String
        let generatedAt: String
        let models: [String: Entry]
    }

    /// The machine the timings came from. Shown beside them, because a realtime
    /// factor without a machine attached is not a fact about anything.
    public static var measuredOn: String? { loaded?.measuredOn }
    public static var generatedAt: String? { loaded?.generatedAt }
    public static var isAvailable: Bool { loaded != nil }

    public static func entry(for modelID: String) -> Entry? {
        loaded?.models[modelID]
    }

    /// Speed as something to read, or nil when there is nothing to say.
    public static func speedLabel(for modelID: String) -> String? {
        guard let entry = entry(for: modelID) else { return nil }
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
