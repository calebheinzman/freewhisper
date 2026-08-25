import Foundation

/// Merges the two capture channels into a single speaker-labelled timeline.
///
/// The microphone channel is by definition the local user, so it needs no
/// diarization at all — only the system channel does. That is the payoff of
/// splitting capture in two, and it makes "you" the one label that is never
/// wrong.
public enum TranscriptAssembler {
    /// Speaker key for the local user.
    public static let localSpeakerID = "you"

    public struct Input {
        public var micSegments: [RawSegment]
        public var systemSegments: [RawSegment]
        public var systemTurns: [SpeakerTurn]
        /// Seconds the system stream started after the mic stream. Positive
        /// values shift system timestamps forward onto the mic's timeline.
        public var systemOffset: TimeInterval
        public var engine: String

        public init(
            micSegments: [RawSegment] = [],
            systemSegments: [RawSegment] = [],
            systemTurns: [SpeakerTurn] = [],
            systemOffset: TimeInterval = 0,
            engine: String
        ) {
            self.micSegments = micSegments
            self.systemSegments = systemSegments
            self.systemTurns = systemTurns
            self.systemOffset = systemOffset
            self.engine = engine
        }
    }

    public static func assemble(_ input: Input) -> Transcript {
        var segments: [TranscriptSegment] = []

        for segment in input.micSegments where !segment.text.isEmpty {
            segments.append(TranscriptSegment(
                start: segment.start,
                end: segment.end,
                text: segment.text,
                channel: .microphone,
                speakerID: localSpeakerID,
                speakerName: "You"
            ))
        }

        for segment in input.systemSegments where !segment.text.isEmpty {
            // Shift onto the mic timeline before matching against turns, which
            // are themselves in system-stream time.
            let shifted = RawSegment(
                start: segment.start + input.systemOffset,
                end: segment.end + input.systemOffset,
                text: segment.text
            )
            let speakerID = attribute(segment, to: input.systemTurns)
            segments.append(TranscriptSegment(
                start: shifted.start,
                end: shifted.end,
                text: shifted.text,
                channel: .system,
                speakerID: speakerID,
                speakerName: speakerID
            ))
        }

        segments.sort { ($0.start, $0.end) < ($1.start, $1.end) }
        segments = suppressEcho(segments)

        return Transcript(
            segments: segments,
            speakerNames: defaultNames(for: segments),
            engine: input.engine
        )
    }

    /// Assign a transcript segment to whichever speaker turn it overlaps most.
    ///
    /// Word-level alignment would be better, but the engines disagree on what
    /// they expose, and maximum overlap is both engine-agnostic and right
    /// almost always — a single transcript segment rarely straddles a speaker
    /// change, because both ASR engines break on the same pauses a diarizer does.
    static func attribute(_ segment: RawSegment, to turns: [SpeakerTurn]) -> String {
        guard !turns.isEmpty else { return "speaker_1" }

        var best: (id: String, overlap: TimeInterval)?
        for turn in turns {
            let overlap = turn.overlap(with: segment)
            guard overlap > 0 else { continue }
            if best == nil || overlap > best!.overlap {
                best = (turn.speakerID, overlap)
            }
        }

        if let best { return best.id }

        // No overlap at all — diarization missed this stretch. Fall back to the
        // nearest turn rather than inventing a speaker.
        let midpoint = (segment.start + segment.end) / 2
        let nearest = turns.min {
            abs(($0.start + $0.end) / 2 - midpoint) < abs(($1.start + $1.end) / 2 - midpoint)
        }
        return nearest?.speakerID ?? "speaker_1"
    }

    /// Drop remote-channel lines that are really the user's own voice echoing
    /// back through the speakers.
    ///
    /// Only matters without headphones. The test is deliberately strict — a
    /// heavy time overlap *and* near-identical text — because wrongly deleting
    /// something a participant actually said is much worse than leaving a
    /// duplicate line in.
    static func suppressEcho(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let micSegments = segments.filter { $0.channel == .microphone }
        guard !micSegments.isEmpty else { return segments }

        return segments.filter { segment in
            guard segment.channel == .system else { return true }

            return !micSegments.contains { mic in
                let overlap = max(0, min(mic.end, segment.end) - max(mic.start, segment.start))
                let shorter = min(mic.end - mic.start, segment.end - segment.start)
                guard shorter > 0, overlap / shorter > 0.6 else { return false }
                return similarity(mic.text, segment.text) > 0.85
            }
        }
    }

    /// Token-level Jaccard similarity, lowercased and stripped of punctuation.
    /// Cheap, and enough to tell an echo from a genuine reply.
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = tokenize(lhs)
        let right = tokenize(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }

        let intersection = left.intersection(right).count
        let union = left.union(right).count
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }

    private static func tokenize(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
    }

    /// "Speaker 1", "Speaker 2"… numbered by when each first spoke, so the
    /// labels match reading order rather than the diarizer's cluster indices.
    static func defaultNames(for segments: [TranscriptSegment]) -> [String: String] {
        var names: [String: String] = [localSpeakerID: "You"]
        var nextNumber = 1

        for segment in segments where segment.speakerID != localSpeakerID {
            guard names[segment.speakerID] == nil else { continue }
            names[segment.speakerID] = "Speaker \(nextNumber)"
            nextNumber += 1
        }
        return names
    }
}
