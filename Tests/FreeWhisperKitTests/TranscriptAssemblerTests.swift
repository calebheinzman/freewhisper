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

    @Test("a segment straddling a speaker change is cut at the change")
    func splitsAtSpeakerChange() {
        let turns = [
            SpeakerTurn(start: 0, end: 2, speakerID: "speaker_0"),
            SpeakerTurn(start: 2, end: 4, speakerID: "speaker_1"),
        ]
        // One ASR segment, two speakers: exactly the case the old whole-segment
        // vote gave entirely to whoever held the longer half.
        let segment = RawSegment(
            start: 0,
            end: 4,
            text: "are we agreed yes we are",
            words: [
                TimedWord(start: 0.0, end: 0.5, text: "are"),
                TimedWord(start: 0.5, end: 1.0, text: "we"),
                TimedWord(start: 1.0, end: 1.8, text: "agreed"),
                TimedWord(start: 2.2, end: 2.6, text: "yes"),
                TimedWord(start: 2.6, end: 3.0, text: "we"),
                TimedWord(start: 3.0, end: 3.6, text: "are"),
            ]
        )

        let pieces = TranscriptAssembler.split(segment, by: turns)
        #expect(pieces.map(\.speakerID) == ["speaker_0", "speaker_1"])
        #expect(pieces.map(\.segment.text) == ["are we agreed", "yes we are"])
        #expect(pieces[0].segment.start == 0.0)
        #expect(pieces[1].segment.start == 2.2)
        #expect(pieces[1].segment.end == 3.6)
    }

    @Test("separately-timed punctuation rejoins without a space before it")
    func joinsPunctuationTightly() {
        let text = TranscriptAssembler.join([
            TimedWord(start: 0, end: 1, text: "Yes"),
            TimedWord(start: 1, end: 1.1, text: ","),
            TimedWord(start: 1.1, end: 2, text: "exactly"),
            TimedWord(start: 2, end: 2.1, text: "."),
        ])
        #expect(text == "Yes, exactly.")
    }

    @Test("a split contraction closes up, but an opening quote keeps its space")
    func joinsContractionsAndQuotes() {
        #expect(
            TranscriptAssembler.join([
                TimedWord(start: 0, end: 1, text: "it"),
                TimedWord(start: 1, end: 1.2, text: "'s"),
                TimedWord(start: 1.2, end: 2, text: "fine"),
            ]) == "it's fine"
        )
        #expect(
            TranscriptAssembler.join([
                TimedWord(start: 0, end: 1, text: "she"),
                TimedWord(start: 1, end: 1.2, text: "said"),
                TimedWord(start: 1.2, end: 2, text: "\"no"),
            ]) == "she said \"no"
        )
    }

    @Test("a segment with no word timings keeps the whole-segment vote")
    func splitFallsBackWithoutWords() {
        let turns = [
            SpeakerTurn(start: 0, end: 2, speakerID: "speaker_0"),
            SpeakerTurn(start: 2, end: 4, speakerID: "speaker_1"),
        ]
        let pieces = TranscriptAssembler.split(segment(1.5, 4, "no words here"), by: turns)

        #expect(pieces.count == 1)
        #expect(pieces[0].speakerID == "speaker_1")
        #expect(pieces[0].segment.text == "no words here")
    }

    /// The diarizer flickers for a word at a time. Cutting on that would make a
    /// sentence into three lines and put one word in a stranger's mouth.
    @Test("a one-word speaker island is smoothed away rather than cut")
    func smoothsSingleWordJitter() {
        #expect(
            TranscriptAssembler.smooth(["a", "a", "b", "a", "a"])
                == ["a", "a", "a", "a", "a"]
        )
        // A genuine change of speaker is two-sided, and must survive.
        #expect(
            TranscriptAssembler.smooth(["a", "a", "b", "b", "b"])
                == ["a", "a", "b", "b", "b"]
        )
    }

    @Test("crosstalk gives every overlapping speaker a turn, and words go to the nearer one")
    func overlappingTurnsAreResolvedLocally() {
        // What `.multiple` now produces: one turn per person talking at once.
        let turns = [
            SpeakerTurn(start: 0, end: 3, speakerID: "speaker_0"),
            SpeakerTurn(start: 2, end: 5, speakerID: "speaker_1"),
        ]
        #expect(
            TranscriptAssembler.speaker(
                at: TimedWord(start: 0.5, end: 1.0, text: "early"), in: turns
            ) == "speaker_0"
        )
        #expect(
            TranscriptAssembler.speaker(
                at: TimedWord(start: 4.0, end: 4.5, text: "late"), in: turns
            ) == "speaker_1"
        )
    }

    @Test("splitting a segment produces one transcript line per speaker")
    func assembleEmitsOneLinePerSpeaker() {
        let transcript = TranscriptAssembler.assemble(.init(
            systemSegments: [RawSegment(
                start: 0,
                end: 4,
                text: "hello hi",
                words: [
                    TimedWord(start: 0.0, end: 1.0, text: "hello"),
                    TimedWord(start: 3.0, end: 3.5, text: "hi"),
                ]
            )],
            systemTurns: [
                SpeakerTurn(start: 0, end: 2, speakerID: "speaker_0"),
                SpeakerTurn(start: 2.5, end: 4, speakerID: "speaker_1"),
            ],
            systemOffset: 1,
            engine: "test"
        ))

        #expect(transcript.segments.map(\.text) == ["hello", "hi"])
        #expect(transcript.name(for: transcript.segments[0].speakerID) == "Speaker 1")
        #expect(transcript.name(for: transcript.segments[1].speakerID) == "Speaker 2")
        // Both halves land on the mic timeline, not just the segment they came from.
        #expect(transcript.segments[0].start == 1.0)
        #expect(transcript.segments[1].start == 4.0)
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

    /// Echo has to be caught before the segment is cut into speaker runs. Each
    /// run on its own is far too short to look like the sentence the user said,
    /// so testing after the split would let every echo through.
    @Test("an echo is dropped even when its words would split it across speakers")
    func dropsEchoThatWouldHaveBeenSplit() {
        let transcript = TranscriptAssembler.assemble(.init(
            micSegments: [segment(0, 3, "Can everyone hear me okay")],
            systemSegments: [RawSegment(
                start: 0,
                end: 3,
                text: "Can everyone hear me okay",
                words: [
                    TimedWord(start: 0.0, end: 0.5, text: "Can"),
                    TimedWord(start: 0.5, end: 1.0, text: "everyone"),
                    TimedWord(start: 1.0, end: 1.4, text: "hear"),
                    TimedWord(start: 2.1, end: 2.4, text: "me"),
                    TimedWord(start: 2.4, end: 2.8, text: "okay"),
                ]
            )],
            // A speaker change mid-utterance, which would otherwise cut it in two.
            systemTurns: [
                SpeakerTurn(start: 0, end: 1.8, speakerID: "speaker_0"),
                SpeakerTurn(start: 1.8, end: 3, speakerID: "speaker_1"),
            ],
            engine: "test"
        ))

        #expect(transcript.segments.count == 1)
        #expect(transcript.segments[0].channel == .microphone)
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

    /// Parakeet decodes sub-word pieces, so the words a speaker label has to be
    /// placed on have to be put back together before they can be timed.
    ///
    /// The tokens here are copied from a real v3 decode: FluidAudio 0.15 marks
    /// a word boundary with a leading space, not the SentencePiece `▁` an
    /// earlier version passed through. Keying on the wrong one is invisible —
    /// the transcript is identical and only the speaker labels quietly get
    /// worse — so it is pinned by a test rather than left to a code comment.
    @Test("a leading space starts a new word, as FluidAudio 0.15 emits them")
    func rejoinsSpaceMarkedPieces() {
        let words = FluidAudioEngine.words(from: [
            token(" H", 0, 0.1),
            token("ow", 0.1, 0.2),
            token(" do", 0.2, 0.3),
            token("es", 0.3, 0.4),
            token(" that", 0.4, 0.6),
            token(" work", 0.6, 0.9),
            token("?", 0.9, 1.0),
        ])

        #expect(words?.map(\.text) == ["How", "does", "that", "work?"])
        #expect(words?[0].start == 0)
        #expect(words?[3].end == 1.0)
    }

    @Test("the older SentencePiece marker still starts a new word")
    func rejoinsSubwordPieces() {
        let words = FluidAudioEngine.words(from: [
            token("\u{2581}It", 0, 0.2),
            token("\u{2581}is", 0.2, 0.4),
            token("\u{2581}un", 0.5, 0.7),
            token("bel", 0.7, 0.9),
            token("ievable", 0.9, 1.2),
        ])

        #expect(words?.map(\.text) == ["It", "is", "unbelievable"])
        #expect(words?[2].start == 0.5)
        #expect(words?[2].end == 1.2)
    }

    /// The failure this guards against: one word per segment is exactly what
    /// the assembler cannot cut, so attribution silently falls back to whole
    /// segments while every other signal says the pipeline is working.
    @Test("a multi-word sentence yields more than one word")
    func sentenceYieldsSeveralWords() {
        let segments = FluidAudioEngine.groupIntoSegments([
            token(" The", 0, 0.2),
            token(" m", 0.2, 0.3),
            token("ic", 0.3, 0.4),
            token(" is", 0.4, 0.6),
            token(" right", 0.6, 0.9),
            token(".", 0.9, 1.0),
        ])

        #expect(segments.count == 1)
        #expect(segments[0].text == "The mic is right.")
        #expect((segments[0].words?.count ?? 0) > 1)
        #expect(segments[0].words?.map(\.text) == ["The", "mic", "is", "right."])
    }

    @Test("punctuation joins the word it follows instead of becoming its own")
    func punctuationAttachesToPreviousWord() {
        let words = FluidAudioEngine.words(from: [
            token("\u{2581}Done", 0, 0.4),
            token(".", 0.4, 0.5),
            token("\u{2581}Next", 0.6, 1.0),
        ])

        #expect(words?.map(\.text) == ["Done.", "Next"])
        #expect(words?[0].end == 0.5)
    }

    @Test("a segment carries the words it was built from")
    func segmentsCarryWords() {
        let segments = FluidAudioEngine.groupIntoSegments([
            token("\u{2581}Hello", 0, 0.4),
            token("\u{2581}there", 0.4, 0.8),
        ])

        #expect(segments.count == 1)
        #expect(segments[0].words?.map(\.text) == ["Hello", "there"])
    }

    @Test("punctuation-only output produces no words")
    func punctuationOnlyProducesNoWords() {
        #expect(FluidAudioEngine.words(from: [token(".", 0, 0.1)]) == nil)
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
