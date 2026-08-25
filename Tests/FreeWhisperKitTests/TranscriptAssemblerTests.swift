import FluidAudio
import Foundation
import Testing

@testable import FreeWhisperKit

@Suite("Transcript assembly")
struct TranscriptAssemblerTests {
    private func segment(_ start: Double, _ end: Double, _ text: String) -> RawSegment {
        RawSegment(start: start, end: end, text: text)
    }

    @Test("the microphone channel is always attributed to You, with no diarization")
    func micIsAlwaysYou() {
        let transcript = TranscriptAssembler.assemble(.init(
            micSegments: [segment(0, 2, "Morning everyone")],
            engine: "test"
        ))

        #expect(transcript.segments.count == 1)
        #expect(transcript.segments[0].speakerID == TranscriptAssembler.localSpeakerID)
        #expect(transcript.name(for: TranscriptAssembler.localSpeakerID) == "You")
    }

    @Test("both channels merge into one timeline ordered by start time")
    func channelsInterleave() {
        let transcript = TranscriptAssembler.assemble(.init(
            micSegments: [segment(0, 2, "Morning"), segment(6, 8, "Sounds good")],
            systemSegments: [segment(2, 5, "Morning, shall we start?")],
            systemTurns: [SpeakerTurn(start: 2, end: 5, speakerID: "speaker_0")],
            engine: "test"
        ))

        #expect(transcript.segments.map(\.text) == [
            "Morning", "Morning, shall we start?", "Sounds good",
        ])
        #expect(transcript.segments.map(\.channel) == [.microphone, .system, .microphone])
    }

    @Test("system timestamps are shifted onto the microphone timeline")
    func offsetIsApplied() {
        let transcript = TranscriptAssembler.assemble(.init(
            systemSegments: [segment(10, 12, "Hello")],
            systemTurns: [SpeakerTurn(start: 10, end: 12, speakerID: "speaker_0")],
            systemOffset: 1.5,
            engine: "test"
        ))

        #expect(transcript.segments[0].start == 11.5)
        #expect(transcript.segments[0].end == 13.5)
    }

    @Test("a segment is attributed to the speaker turn it overlaps most")
    func attributionUsesMaximumOverlap() {
        let turns = [
            SpeakerTurn(start: 0, end: 5, speakerID: "speaker_0"),
            SpeakerTurn(start: 4.5, end: 10, speakerID: "speaker_1"),
        ]
        // Overlaps speaker_0 for 0.5s and speaker_1 for 3.5s.
        let id = TranscriptAssembler.attribute(segment(4.5, 8, "mostly the second one"), to: turns)
        #expect(id == "speaker_1")
    }

    @Test("a segment with no overlapping turn falls back to the nearest one")
    func attributionFallsBackToNearest() {
        let turns = [
            SpeakerTurn(start: 0, end: 2, speakerID: "speaker_0"),
            SpeakerTurn(start: 20, end: 25, speakerID: "speaker_1"),
        ]
        let id = TranscriptAssembler.attribute(segment(21, 22, "in the gap"), to: turns)
        #expect(id == "speaker_1")
    }

    @Test("with no diarization at all, remote speech still gets a speaker")
    func attributionWithoutTurns() {
        let transcript = TranscriptAssembler.assemble(.init(
            systemSegments: [segment(0, 2, "Hello")],
            systemTurns: [],
            engine: "test"
        ))
        #expect(transcript.segments.count == 1)
        #expect(transcript.name(for: transcript.segments[0].speakerID) == "Speaker 1")
    }

    @Test("speakers are numbered by when they first spoke, not by cluster index")
    func speakersNumberedByFirstAppearance() {
        let transcript = TranscriptAssembler.assemble(.init(
            systemSegments: [segment(0, 2, "first"), segment(3, 5, "second")],
            systemTurns: [
                // Cluster ids deliberately out of order.
                SpeakerTurn(start: 0, end: 2, speakerID: "speaker_7"),
                SpeakerTurn(start: 3, end: 5, speakerID: "speaker_2"),
            ],
            engine: "test"
        ))

        #expect(transcript.name(for: "speaker_7") == "Speaker 1")
        #expect(transcript.name(for: "speaker_2") == "Speaker 2")
    }
}

@Suite("Echo suppression")
struct EchoSuppressionTests {
    private func segment(_ start: Double, _ end: Double, _ text: String) -> RawSegment {
        RawSegment(start: start, end: end, text: text)
    }

    /// On speakers rather than headphones, the user's own voice bleeds into the
    /// system tap and gets transcribed twice.
    @Test("the user's voice echoing through the speakers is dropped")
    func dropsEcho() {
        let transcript = TranscriptAssembler.assemble(.init(
            micSegments: [segment(0, 3, "Can everyone hear me okay?")],
            systemSegments: [segment(0, 3, "Can everyone hear me okay")],
            systemTurns: [SpeakerTurn(start: 0, end: 3, speakerID: "speaker_0")],
            engine: "test"
        ))

        #expect(transcript.segments.count == 1)
        #expect(transcript.segments[0].channel == .microphone)
    }

    /// Deleting something a participant genuinely said is far worse than
    /// leaving a duplicate line in, so these must all survive.
    @Test("a genuine reply at the same moment is kept")
    func keepsGenuineOverlap() {
        let transcript = TranscriptAssembler.assemble(.init(
            micSegments: [segment(0, 3, "Can everyone hear me okay?")],
            systemSegments: [segment(0, 3, "Yes, loud and clear thanks")],
            systemTurns: [SpeakerTurn(start: 0, end: 3, speakerID: "speaker_0")],
            engine: "test"
        ))
        #expect(transcript.segments.count == 2)
    }

    @Test("identical words said at a different time are kept")
    func keepsRepeatedPhraseLater() {
        let transcript = TranscriptAssembler.assemble(.init(
            micSegments: [segment(0, 3, "Sounds good to me")],
            systemSegments: [segment(30, 33, "Sounds good to me")],
            systemTurns: [SpeakerTurn(start: 30, end: 33, speakerID: "speaker_0")],
            engine: "test"
        ))
        #expect(transcript.segments.count == 2)
    }

    @Test("similarity is word-order and punctuation insensitive")
    func similarityScoring() {
        #expect(TranscriptAssembler.similarity("Hello there", "hello there!") > 0.9)
        #expect(TranscriptAssembler.similarity("Hello there", "goodbye now") < 0.2)
        #expect(TranscriptAssembler.similarity("", "anything") == 0)
    }
}

@Suite("Parakeet token grouping")
struct ParakeetGroupingTests {
    private func token(_ text: String, _ start: Double, _ end: Double) -> TokenTiming {
        TokenTiming(token: text, tokenId: 0, startTime: start, endTime: end, confidence: 1)
    }

    /// Parakeet returns a flat token stream where Whisper returns segments;
    /// grouping is what makes the two engines interchangeable downstream.
    @Test("a long pause starts a new segment")
    func splitsOnPause() {
        let segments = FluidAudioEngine.groupIntoSegments([
            token("\u{2581}Hello", 0, 0.4),
            token("\u{2581}there", 0.4, 0.8),
            // 2s gap.
            token("\u{2581}Right", 2.8, 3.2),
            token("\u{2581}then", 3.2, 3.6),
        ])

        #expect(segments.count == 2)
        #expect(segments[0].text == "Hello there")
        #expect(segments[1].text == "Right then")
        #expect(segments[0].start == 0)
        #expect(segments[1].start == 2.8)
    }

    @Test("a sentence ending starts a new segment")
    func splitsOnSentenceEnd() {
        let segments = FluidAudioEngine.groupIntoSegments([
            token("\u{2581}Done", 0, 0.4),
            token(".", 0.4, 0.5),
            token("\u{2581}Next", 0.6, 1.0),
        ])
        #expect(segments.count == 2)
        #expect(segments[0].text == "Done.")
    }

    @Test("punctuation-only output produces no segments")
    func dropsPunctuationOnly() {
        let segments = FluidAudioEngine.groupIntoSegments([token(".", 0, 0.1)])
        #expect(segments.isEmpty)
    }

    @Test("an empty token stream is handled")
    func handlesEmpty() {
        #expect(FluidAudioEngine.groupIntoSegments([]).isEmpty)
    }
}

@Suite("Transcript rendering")
struct TranscriptRenderingTests {
    @Test("markdown groups consecutive lines under one speaker heading")
    func markdownGroupsSpeakers() {
        let transcript = Transcript(
            segments: [
                TranscriptSegment(start: 0, end: 1, text: "One", channel: .system, speakerID: "s1", speakerName: "s1"),
                TranscriptSegment(start: 1, end: 2, text: "Two", channel: .system, speakerID: "s1", speakerName: "s1"),
                TranscriptSegment(start: 2, end: 3, text: "Three", channel: .microphone, speakerID: "you", speakerName: "You"),
            ],
            speakerNames: ["s1": "Alice", "you": "You"],
            engine: "test"
        )

        let markdown = transcript.markdown(title: "Standup")
        #expect(markdown.contains("# Standup"))
        // Alice speaks twice in a row but should be introduced only once.
        #expect(markdown.components(separatedBy: "**Alice**").count - 1 == 1)
        #expect(markdown.contains("**You**"))
    }

    @Test("timestamps switch to hours only when needed")
    func timestampFormatting() {
        #expect(Transcript.timestamp(65) == "1:05")
        #expect(Transcript.timestamp(3665) == "1:01:05")
        #expect(Transcript.timestamp(0) == "0:00")
    }

    @Test("punctuation-only text is not treated as speech")
    func speechDetection() {
        #expect(!".".containsSpeech)
        #expect(!"...".containsSpeech)
        #expect(!"  - ".containsSpeech)
        #expect("Okay.".containsSpeech)
        #expect("42".containsSpeech)
    }
}
