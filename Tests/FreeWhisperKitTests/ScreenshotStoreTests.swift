import Foundation
import Testing

@testable import FreeWhisperKit

@Suite("Meeting screenshots")
struct ScreenshotStoreTests {
    /// Each test gets its own root so nothing touches the user's real meetings.
    private func makeStore() -> (MeetingStore, ScreenshotStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fw-tests-\(UUID().uuidString)", isDirectory: true)
        let store = MeetingStore(root: root)
        return (store, ScreenshotStore(store: store))
    }

    /// A one-pixel PNG. Enough to prove the bytes make the round trip without
    /// dragging a real capture — which needs a TCC grant — into a unit test.
    private var pixelPNG: Data {
        Data(base64Encoded: """
            iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmM\
            IQAAAABJRU5ErkJggg==
            """)!
    }

    // MARK: Timeline

    /// The bug this guards: screenshots offset from `startedAt` land ahead of
    /// where the transcript thinks the same moment is, because the assembler
    /// works off the mic stream's clock — and the gap between the two is however
    /// long the system-audio permission prompt sat on screen.
    @Test("timeline origin is the mic stream, not the meeting start")
    func timelineOriginPrefersMic() {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let mic = started.addingTimeInterval(4.25)
        let system = started.addingTimeInterval(4.5)

        var metadata = MeetingMetadata(id: "m", startedAt: started, micStartedAt: mic, systemStartedAt: system)
        #expect(metadata.timelineOrigin == mic)

        // No mic: the system stream is the timeline, because the assembler
        // leaves system segments unshifted when there is nothing to shift onto.
        metadata.micStartedAt = nil
        #expect(metadata.timelineOrigin == system)

        // Neither stream ever opened; all that is left is when we asked.
        metadata.systemStartedAt = nil
        #expect(metadata.timelineOrigin == started)
    }

    // MARK: Manifest

    @Test("screenshots round-trip through the manifest")
    func roundTrip() throws {
        let (store, screenshots) = makeStore()
        let (metadata, _) = try store.createMeeting(startedAt: Date())

        let saved = try screenshots.append(
            pngs: [(data: pixelPNG, displayID: 7, pixelWidth: 100, pixelHeight: 50)],
            offset: 12.5,
            meetingID: metadata.id
        )

        let loaded = screenshots.load(meetingID: metadata.id)
        #expect(loaded.count == 1)
        let first = try #require(loaded.first)
        #expect(first.id == saved.id)
        #expect(first.offset == 12.5)
        #expect(first.images == saved.images)
        // Stored to the millisecond, like every other date in the meeting
        // directory — not to the microsecond `Date()` actually carries.
        #expect(abs(first.capturedAt.timeIntervalSince(saved.capturedAt)) < 0.001)
    }

    @Test("a meeting with no screenshots reads as empty, not as an error")
    func emptyWhenAbsent() throws {
        let (store, screenshots) = makeStore()
        let (metadata, _) = try store.createMeeting(startedAt: Date())
        #expect(screenshots.load(meetingID: metadata.id).isEmpty)
        #expect(screenshots.load(meetingID: "never-recorded").isEmpty)
    }

    @Test("one press across two displays is one entry with two images")
    func multipleDisplaysGroupIntoOneEntry() throws {
        let (store, screenshots) = makeStore()
        let (metadata, paths) = try store.createMeeting(startedAt: Date())

        let saved = try screenshots.append(
            pngs: [
                (data: pixelPNG, displayID: 1, pixelWidth: 3840, pixelHeight: 2160),
                (data: pixelPNG, displayID: 2, pixelWidth: 2560, pixelHeight: 1440),
            ],
            offset: 30,
            meetingID: metadata.id
        )

        #expect(saved.images.count == 2)
        #expect(screenshots.load(meetingID: metadata.id).count == 1)

        for image in saved.images {
            let url = paths.directory.appendingPathComponent(image.relativePath)
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(image.relativePath.hasPrefix("screenshots/"))
        }
    }

    @Test("entries come back in timeline order however they were written")
    func loadsInOffsetOrder() throws {
        let (store, screenshots) = makeStore()
        let (metadata, _) = try store.createMeeting(startedAt: Date())

        for offset in [90.0, 10.0, 50.0] {
            try screenshots.append(
                pngs: [(data: pixelPNG, displayID: 1, pixelWidth: 10, pixelHeight: 10)],
                offset: offset,
                meetingID: metadata.id
            )
        }

        #expect(screenshots.load(meetingID: metadata.id).map(\.offset) == [10, 50, 90])
    }

    /// Two captures in the same second would otherwise resolve to the same
    /// filename, and the second would quietly overwrite the first.
    @Test("captures within the same second don't overwrite each other")
    func sameSecondCapturesGetDistinctFiles() throws {
        let (store, screenshots) = makeStore()
        let (metadata, _) = try store.createMeeting(startedAt: Date())

        let first = try screenshots.append(
            pngs: [(data: pixelPNG, displayID: 1, pixelWidth: 10, pixelHeight: 10)],
            offset: 20.1,
            meetingID: metadata.id
        )
        let second = try screenshots.append(
            pngs: [(data: pixelPNG, displayID: 1, pixelWidth: 10, pixelHeight: 10)],
            offset: 20.8,
            meetingID: metadata.id
        )

        #expect(first.images[0].relativePath != second.images[0].relativePath)
        #expect(screenshots.load(meetingID: metadata.id).count == 2)
    }

    @Test("capturing nothing is an error rather than an empty entry")
    func emptyCaptureThrows() throws {
        let (store, screenshots) = makeStore()
        let (metadata, _) = try store.createMeeting(startedAt: Date())

        #expect(throws: ScreenshotError.self) {
            try screenshots.append(pngs: [], offset: 0, meetingID: metadata.id)
        }
    }

    @Test("deleting a screenshot removes its files too")
    func deleteRemovesFiles() throws {
        let (store, screenshots) = makeStore()
        let (metadata, paths) = try store.createMeeting(startedAt: Date())

        let saved = try screenshots.append(
            pngs: [
                (data: pixelPNG, displayID: 1, pixelWidth: 10, pixelHeight: 10),
                (data: pixelPNG, displayID: 2, pixelWidth: 10, pixelHeight: 10),
            ],
            offset: 5,
            meetingID: metadata.id
        )
        let urls = saved.images.map { paths.directory.appendingPathComponent($0.relativePath) }

        try screenshots.delete(id: saved.id, meetingID: metadata.id)

        #expect(screenshots.load(meetingID: metadata.id).isEmpty)
        for url in urls {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("deleting the whole meeting takes the screenshots with it")
    func deletingMeetingRemovesScreenshots() throws {
        let (store, screenshots) = makeStore()
        let (metadata, paths) = try store.createMeeting(startedAt: Date())
        try screenshots.append(
            pngs: [(data: pixelPNG, displayID: 1, pixelWidth: 10, pixelHeight: 10)],
            offset: 5,
            meetingID: metadata.id
        )

        try store.delete(id: metadata.id)
        #expect(!FileManager.default.fileExists(atPath: paths.screenshotsDirectory.path))
    }

    // MARK: Markdown

    private func transcript() -> Transcript {
        Transcript(
            segments: [
                TranscriptSegment(start: 0, end: 5, text: "Morning.", channel: .microphone, speakerID: "you", speakerName: "You"),
                TranscriptSegment(start: 60, end: 65, text: "Look at this chart.", channel: .system, speakerID: "speaker_1", speakerName: "Speaker 1"),
            ],
            speakerNames: ["you": "You", "speaker_1": "Alex"],
            engine: "whisperKit"
        )
    }

    private func screenshot(at offset: TimeInterval, path: String) -> MeetingScreenshot {
        MeetingScreenshot(
            offset: offset,
            images: [ScreenshotImage(relativePath: path, displayID: 1, pixelWidth: 10, pixelHeight: 10)]
        )
    }

    @Test("markdown is unchanged when there are no screenshots")
    func markdownWithoutScreenshots() {
        let plain = transcript().markdown(title: "Standup")
        #expect(!plain.contains("!["))
        #expect(plain.contains("**You** _(0:00)_"))
        #expect(plain.contains("**Alex** _(1:00)_"))
    }

    @Test("a screenshot lands between the turns that bracket it")
    func markdownInterleavesMidTranscript() {
        let markdown = transcript().markdown(
            title: "Standup",
            screenshots: [screenshot(at: 30, path: "screenshots/000030-1.png")]
        )

        let image = try! #require(markdown.range(of: "![Screenshot at 0:30](screenshots/000030-1.png)"))
        let first = try! #require(markdown.range(of: "Morning."))
        let second = try! #require(markdown.range(of: "Look at this chart."))

        #expect(first.upperBound < image.lowerBound)
        #expect(image.upperBound < second.lowerBound)
    }

    /// Both ends of the timeline: a screenshot taken before anyone spoke, and
    /// one taken after the last word. The second is the easy one to drop — it
    /// has no following segment to trigger the flush.
    @Test("screenshots outside the speech still appear")
    func markdownHandlesEdges() {
        let markdown = transcript().markdown(
            title: "Standup",
            screenshots: [
                screenshot(at: 0, path: "screenshots/000000-1.png"),
                screenshot(at: 600, path: "screenshots/000600-1.png"),
            ]
        )

        #expect(markdown.contains("screenshots/000000-1.png"))
        #expect(markdown.contains("screenshots/000600-1.png"))

        let trailing = try! #require(markdown.range(of: "screenshots/000600-1.png"))
        let lastSpeech = try! #require(markdown.range(of: "Look at this chart."))
        #expect(lastSpeech.upperBound < trailing.lowerBound)
    }

    @Test("a two-display capture writes both images at the same point")
    func markdownEmitsEveryDisplay() {
        let both = MeetingScreenshot(
            offset: 30,
            images: [
                ScreenshotImage(relativePath: "screenshots/000030-1.png", displayID: 1, pixelWidth: 10, pixelHeight: 10),
                ScreenshotImage(relativePath: "screenshots/000030-2.png", displayID: 2, pixelWidth: 10, pixelHeight: 10),
            ]
        )
        let markdown = transcript().markdown(title: "Standup", screenshots: [both])
        #expect(markdown.contains("screenshots/000030-1.png"))
        #expect(markdown.contains("screenshots/000030-2.png"))
    }

    /// A screenshot interrupts the run of turns, so the speaker heading has to
    /// be reprinted afterwards — otherwise the following line reads as a caption.
    @Test("the speaker heading is reprinted after a screenshot")
    func markdownReprintsSpeakerAfterScreenshot() {
        let sameSpeaker = Transcript(
            segments: [
                TranscriptSegment(start: 0, end: 5, text: "One.", channel: .microphone, speakerID: "you", speakerName: "You"),
                TranscriptSegment(start: 60, end: 65, text: "Two.", channel: .microphone, speakerID: "you", speakerName: "You"),
            ],
            speakerNames: ["you": "You"],
            engine: "whisperKit"
        )

        let markdown = sameSpeaker.markdown(
            title: "Standup",
            screenshots: [screenshot(at: 30, path: "screenshots/000030-1.png")]
        )

        #expect(markdown.components(separatedBy: "**You**").count - 1 == 2)
    }

    // MARK: Timeline

    /// The regression this guards, found on screen rather than in a test: when
    /// one person does most of the talking, every segment collapses into a
    /// single turn spanning the whole meeting. Merging finished turns by start
    /// time then puts a screenshot taken thirty seconds in *after* the entire
    /// conversation, because the block it belongs inside starts at 0:02.
    @Test("a screenshot splits a speaker run rather than sorting after it")
    func timelineSplitsLongRuns() {
        let monologue = Transcript(
            segments: [
                TranscriptSegment(start: 2, end: 8, text: "Morning.", channel: .system, speakerID: "s1", speakerName: "Alex"),
                TranscriptSegment(start: 40, end: 46, text: "And that's the plan.", channel: .system, speakerID: "s1", speakerName: "Alex"),
            ],
            speakerNames: ["s1": "Alex"],
            engine: "whisperKit"
        )

        let entries = TranscriptTimeline.entries(
            transcript: monologue,
            screenshots: [screenshot(at: 20, path: "screenshots/000020-1.png")]
        )

        #expect(entries.count == 3)
        guard case .turn(let first) = entries[0],
              case .screenshot = entries[1],
              case .turn(let second) = entries[2]
        else {
            Issue.record("expected turn, screenshot, turn — got \(entries)")
            return
        }
        #expect(first.text == "Morning.")
        #expect(second.text == "And that's the plan.")
        #expect(second.start == 40)
    }

    @Test("with no screenshots, consecutive same-speaker segments stay one turn")
    func timelineGroupsWithoutScreenshots() {
        let entries = TranscriptTimeline.entries(transcript: transcript())
        #expect(entries.count == 2) // one per speaker, not one per segment
    }

    /// Turn ids come from the first segment, which is persisted in
    /// transcript.json — so they survive a redraw and the scroll position with
    /// them. A freshly generated UUID would make every recompute look like new
    /// rows to SwiftUI.
    @Test("turn identity is stable across recomputes")
    func timelineTurnIDsAreStable() {
        let transcript = transcript()
        let first = TranscriptTimeline.entries(transcript: transcript).map(\.id)
        let second = TranscriptTimeline.entries(transcript: transcript).map(\.id)
        #expect(first == second)
        #expect(first.first == transcript.segments.first?.id)
    }

    @Test("the on-screen order and the Markdown order agree")
    func timelineMatchesMarkdown() {
        let shots = [
            screenshot(at: 0, path: "screenshots/000000-1.png"),
            screenshot(at: 30, path: "screenshots/000030-1.png"),
            screenshot(at: 600, path: "screenshots/000600-1.png"),
        ]
        let entries = TranscriptTimeline.entries(transcript: transcript(), screenshots: shots)
        let markdown = transcript().markdown(title: "Standup", screenshots: shots)

        // Every entry appears in the export, in the same sequence.
        var cursor = markdown.startIndex
        for entry in entries {
            let needle = switch entry {
            case .turn(let turn): turn.texts[0]
            case .screenshot(let shot): shot.images[0].relativePath
            }
            let found = try! #require(markdown.range(of: needle, range: cursor..<markdown.endIndex))
            cursor = found.upperBound
        }
    }

    @Test("filenames are zero-padded so they sort chronologically")
    func filenameStemSorts() {
        #expect(MeetingScreenshot.filenameStem(offset: 7) == "000007")
        #expect(MeetingScreenshot.filenameStem(offset: 3725.9) == "003725")
        // A capture during the streams' startup gap has a negative offset;
        // clamping keeps it a valid filename rather than "-00001".
        #expect(MeetingScreenshot.filenameStem(offset: -3) == "000000")
        #expect(MeetingScreenshot.filenameStem(offset: 7) < MeetingScreenshot.filenameStem(offset: 70))
    }

    @Test("timestamps read the same way the transcript labels turns")
    func timestampMatchesTranscript() {
        #expect(MeetingScreenshot(offset: 165, images: []).timestampText == "2:45")
        #expect(MeetingScreenshot(offset: 3725, images: []).timestampText == "1:02:05")
    }
}
