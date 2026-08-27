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
        let micSegments = input.micSegments.filter { !$0.text.isEmpty }

        for segment in micSegments {
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
            // Shift onto the mic timeline to test for echo, but keep the
            // original for attribution — the turns are in system-stream time.
            let shifted = RawSegment(
                start: segment.start + input.systemOffset,
                end: segment.end + input.systemOffset,
                text: segment.text
            )
            // Echo is judged on the whole utterance, before it is cut into
            // speaker runs. The test needs near-identical text, and a run of
            // three words out of a sentence cannot look near-identical to the
            // sentence it came from — splitting first would let every echo
            // through by making both halves of the comparison too small.
            guard !isEcho(shifted, of: micSegments) else { continue }

            for piece in split(segment, by: input.systemTurns) {
                segments.append(TranscriptSegment(
                    start: piece.segment.start + input.systemOffset,
                    end: piece.segment.end + input.systemOffset,
                    text: piece.segment.text,
                    channel: .system,
                    speakerID: piece.speakerID,
                    speakerName: piece.speakerID
                ))
            }
        }

        segments.sort { ($0.start, $0.end) < ($1.start, $1.end) }

        return Transcript(
            segments: segments,
            speakerNames: defaultNames(for: segments),
            engine: input.engine
        )
    }

    /// One run of consecutive words that a single speaker said.
    struct AttributedSegment: Equatable {
        var speakerID: String
        var segment: RawSegment
    }

    /// Cut a transcript segment at its speaker changes.
    ///
    /// The assumption this replaces was that a segment rarely straddles a
    /// speaker change. It does — constantly, once more than two people are on
    /// the call — and `eval/calibrate_der.py` priced it: on the AMI headset mix
    /// the diarizer's own turns scored 0.15 DER and the transcript built from
    /// them scored 0.34. More than half the speaker accuracy was being spent
    /// here, on a vote that gave a whole segment to whoever happened to hold
    /// the longest piece of it.
    ///
    /// So attribute each word, then cut where the speaker changes. The same
    /// check now reads 0.095 and 0.152. Segments without word timings keep the
    /// old whole-segment vote, which is the best available when the engine
    /// gives us nothing finer.
    static func split(_ segment: RawSegment, by turns: [SpeakerTurn]) -> [AttributedSegment] {
        guard let words = segment.words, !words.isEmpty else {
            return [AttributedSegment(speakerID: attribute(segment, to: turns), segment: segment)]
        }

        let speakers = smooth(words.map { speaker(at: $0, in: turns) })

        var pieces: [AttributedSegment] = []
        var index = 0
        while index < words.count {
            let speakerID = speakers[index]
            var end = index
            while end + 1 < words.count, speakers[end + 1] == speakerID { end += 1 }

            let run = Array(words[index...end])
            let text = join(run)
            if text.containsSpeech, let first = run.first, let last = run.last {
                pieces.append(AttributedSegment(
                    speakerID: speakerID,
                    segment: RawSegment(
                        start: first.start,
                        end: max(last.end, first.start),
                        text: text,
                        words: run
                    )
                ))
            }
            index = end + 1
        }

        return pieces.isEmpty
            ? [AttributedSegment(speakerID: attribute(segment, to: turns), segment: segment)]
            : pieces
    }

    /// Put words back into a sentence.
    ///
    /// A plain `joined(separator: " ")` would be right for every word and wrong
    /// for the punctuation some engines time separately, which would come back
    /// as "yes , exactly ." It is rare — four segments in seven thousand — but
    /// it is the kind of wrong that makes a transcript look machine-made.
    ///
    /// An opening bracket or quote is the exception that still takes its space,
    /// because it belongs to the word after it rather than the word before. A
    /// leading apostrophe is deliberately *not* on that list: "'s" and "'re"
    /// split off a contraction are far more common than an opening single
    /// quote, and "it 's" is worse than the quote being tight.
    static func join(_ words: [TimedWord]) -> String {
        words.reduce(into: "") { text, word in
            let opensSomething = word.text.first.map { "([{\"".contains($0) } ?? false
            let isPunctuation = word.text.first.map { !$0.isLetter && !$0.isNumber } ?? false
            if !text.isEmpty, opensSomething || !isPunctuation { text += " " }
            text += word.text
        }
    }

    /// A single word between two runs of the same speaker is diarizer jitter,
    /// not a turn. Left alone it would cut one sentence into three lines and
    /// hand the middle word to somebody who never said it, so give it back to
    /// the speaker on both sides of it.
    static func smooth(_ speakers: [String]) -> [String] {
        guard speakers.count > 2 else { return speakers }

        var smoothed = speakers
        for index in 1..<(speakers.count - 1)
        where speakers[index - 1] == speakers[index + 1] && speakers[index] != speakers[index - 1] {
            smoothed[index] = speakers[index - 1]
        }
        return smoothed
    }

    /// Which speaker was talking during one word.
    static func speaker(at word: TimedWord, in turns: [SpeakerTurn]) -> String {
        attribute(RawSegment(start: word.start, end: word.end, text: word.text), to: turns)
    }

    /// Assign a span to whichever speaker turn it overlaps most.
    ///
    /// Turns may overlap each other — crosstalk is emitted as one turn per
    /// person talking — so "most" is a real choice between people who were both
    /// speaking, rather than a formality.
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

    /// Is this remote-channel line really the user's own voice echoing back
    /// through the speakers?
    ///
    /// Only matters without headphones. The test is deliberately strict — a
    /// heavy time overlap *and* near-identical text — because wrongly deleting
    /// something a participant actually said is much worse than leaving a
    /// duplicate line in. Both spans must already be on the mic timeline.
    static func isEcho(_ segment: RawSegment, of micSegments: [RawSegment]) -> Bool {
        micSegments.contains { mic in
            let overlap = max(0, min(mic.end, segment.end) - max(mic.start, segment.start))
            let shorter = min(mic.end - mic.start, segment.end - segment.start)
            guard shorter > 0, overlap / shorter > 0.6 else { return false }
            return similarity(mic.text, segment.text) > 0.85
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
