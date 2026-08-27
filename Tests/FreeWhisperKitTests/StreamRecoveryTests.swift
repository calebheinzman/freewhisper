import AVFoundation
import Foundation
import Testing

@testable import FreeWhisperKit

@Suite("Capture segments on disk")
struct AudioSegmentTests {
    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fw-segments-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("the base file is the start of the stream")
    func baseFileIsZero() {
        #expect(MeetingPaths.offset(ofSegment: "mic.wav", in: .microphone) == 0)
        #expect(MeetingPaths.offset(ofSegment: "system.wav", in: .system) == 0)
    }

    @Test("a numbered sibling carries its offset in seconds")
    func numberedSegment() {
        #expect(MeetingPaths.offset(ofSegment: "system-2622.wav", in: .system) == 2622)
        #expect(MeetingPaths.offset(ofSegment: "mic-90.wav", in: .microphone) == 90)
    }

    @Test("the two streams never claim each other's files")
    func streamsDoNotOverlap() {
        #expect(MeetingPaths.offset(ofSegment: "system.wav", in: .microphone) == nil)
        #expect(MeetingPaths.offset(ofSegment: "mic-90.wav", in: .system) == nil)
    }

    @Test("everything else in a meeting directory is ignored")
    func ignoresOtherFiles() {
        for name in ["meta.json", "transcript.md", "mic.json", "mic-.wav", "mic-abc.wav", "micro.wav"] {
            #expect(MeetingPaths.offset(ofSegment: name, in: .microphone) == nil)
        }
    }

    @Test("segments come back in timeline order, not directory order")
    func segmentsAreOrdered() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for name in ["system-2627.wav", "system.wav", "system-2622.wav", "mic.wav", "meta.json"] {
            try Data().write(to: directory.appendingPathComponent(name))
        }

        let paths = MeetingPaths(directory: directory)
        #expect(paths.segments(of: .system).map(\.offset) == [0, 2622, 2627])
        #expect(paths.segments(of: .microphone).map(\.offset) == [0])
    }

    @Test("two restarts in the same second do not overwrite each other")
    func segmentNamesAreUnique() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let paths = MeetingPaths(directory: directory)
        let first = paths.audioSegment(.system, restartedAt: 2622.4)
        try Data().write(to: first)
        let second = paths.audioSegment(.system, restartedAt: 2622.8)

        #expect(first.lastPathComponent == "system-2622.wav")
        #expect(second.lastPathComponent == "system-2623.wav")
    }

    /// `mic-0.wav` would parse as offset zero and collide with `mic.wav`, so a
    /// restart in the first second has to name itself something else.
    @Test("a restart in the very first second cannot shadow the base file")
    func segmentNeverCollidesWithBase() {
        let paths = MeetingPaths(directory: makeDirectory())
        #expect(paths.audioSegment(.microphone, restartedAt: 0.4).lastPathComponent == "mic-1.wav")
    }
}

@Suite("Detecting a dead capture stream")
struct StreamWatchdogTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("a stream that keeps writing is left alone")
    func healthyStreamIsNotRestarted() {
        var watchdog = StreamWatchdog(startedAt: start)
        for second in 1...600 {
            let now = start.addingTimeInterval(Double(second))
            let restarted = watchdog.shouldRestart(captured: Double(second), forced: false, now: now)
            #expect(!restarted)
        }
    }

    /// The failure this exists for: the stream reports itself as running and
    /// writes nothing. Silence is not this — a muted mic still writes zeroes —
    /// so captured seconds standing still means the stream is gone.
    @Test("a stream that stops writing is restarted")
    func stalledStreamIsRestarted() {
        var watchdog = StreamWatchdog(startedAt: start)
        let alive = watchdog.shouldRestart(captured: 100, forced: false, now: start.addingTimeInterval(100))
        #expect(!alive)

        // Still 100 seconds captured, however long we wait.
        let earlyOn = watchdog.shouldRestart(captured: 100, forced: false, now: start.addingTimeInterval(103))
        #expect(!earlyOn)
        let pastTolerance = watchdog.shouldRestart(captured: 100, forced: false, now: start.addingTimeInterval(107))
        #expect(pastTolerance)
    }

    @Test("a stream that says it is broken is restarted at once")
    func forcedRestartSkipsTheWait() {
        var watchdog = StreamWatchdog(startedAt: start)
        let alive = watchdog.shouldRestart(captured: 100, forced: false, now: start.addingTimeInterval(100))
        #expect(!alive)
        let forced = watchdog.shouldRestart(captured: 100, forced: true, now: start.addingTimeInterval(101))
        #expect(forced)
    }

    /// A device that is gone for the rest of the meeting must not produce a new
    /// file every few seconds until it ends.
    @Test("repeated restarts back off")
    func restartsBackOff() {
        var watchdog = StreamWatchdog(startedAt: start)
        var restarts = 0
        for second in 1...600 where watchdog.shouldRestart(
            captured: 0,
            forced: true,
            now: start.addingTimeInterval(Double(second))
        ) {
            restarts += 1
        }

        // 0s, then 5, 10, 20, 40 and 60s apart — a handful over ten minutes
        // rather than one every second.
        #expect(restarts > 3)
        #expect(restarts < 20)
    }

    @Test("a stream that recovers gets its fast retry back")
    func recoveryClearsTheBackoff() {
        var watchdog = StreamWatchdog(startedAt: start)
        let restarted = watchdog.shouldRestart(captured: 0, forced: true, now: start)
        #expect(restarted)
        #expect(watchdog.backoff > 0)

        // Half a minute of audio out of the rebuilt stream is a real recovery.
        var captured: TimeInterval = 0
        for second in 1...30 {
            captured += 1
            _ = watchdog.shouldRestart(
                captured: captured,
                forced: false,
                now: start.addingTimeInterval(Double(second))
            )
        }
        #expect(watchdog.backoff == 0)
    }
}

@Suite("Rejoining a restarted stream")
struct StreamJoinerTests {
    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fw-join-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A tone rather than silence, so a piece that goes missing is visible in
    /// the joined file's length rather than blending into it.
    private func writeTone(seconds: Double, to url: URL) throws {
        let rate = Float(AudioFormats.sampleRate)
        let frames = Int(seconds * AudioFormats.sampleRate)
        var samples: [Float] = []
        samples.reserveCapacity(frames)
        for frame in 0..<frames {
            let phase: Float = 2 * .pi * 440 * Float(frame) / rate
            samples.append(0.5 * sin(phase))
        }
        try AudioLoader.write(samples, to: url)
    }

    @Test("an unbroken stream is handed back untouched")
    func singleSegmentPassesThrough() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let paths = MeetingPaths(directory: directory)
        try writeTone(seconds: 1, to: paths.micAudio)

        let joined = try #require(try StreamJoiner.join(paths.segments(of: .microphone)))
        defer { joined.cleanUp() }

        #expect(joined.url == paths.micAudio)
        #expect(!joined.isTemporary)
        #expect(joined.time(0.5) == 0.5)
    }

    @Test("nothing captured is not an error")
    func noSegments() throws {
        let paths = MeetingPaths(directory: makeDirectory())
        #expect(try StreamJoiner.join(paths.segments(of: .microphone)) == nil)
    }

    @Test("the pieces are joined into one file of their combined length")
    func joinsPieces() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let paths = MeetingPaths(directory: directory)
        try writeTone(seconds: 2, to: paths.systemAudio)
        try writeTone(seconds: 3, to: directory.appendingPathComponent("system-10.wav"))

        let joined = try #require(try StreamJoiner.join(paths.segments(of: .system)))
        defer { joined.cleanUp() }

        #expect(joined.isTemporary)
        // Five seconds of audio, not the fifteen the two pieces span. The gap
        // is dead air nobody needs the engine to listen to.
        #expect(abs(AudioLoader.duration(of: joined.url) - 5) < 0.05)
    }

    /// The whole point of joining: a timestamp from the second piece has to come
    /// back where it was said, not where it landed after the gap was closed.
    @Test("timestamps are rebased across the gap")
    func rebasesAcrossTheGap() {
        let joined = JoinedStream(
            url: URL(fileURLWithPath: "/dev/null"),
            isTemporary: false,
            pieces: [.init(start: 0, offset: 0), .init(start: 2, offset: 10)]
        )

        // Before the seam, nothing moves.
        #expect(joined.time(0) == 0)
        #expect(joined.time(1.5) == 1.5)
        // After it, everything shifts by the eight seconds that were missing.
        #expect(joined.time(2) == 10)
        #expect(joined.time(4.5) == 12.5)
    }

    @Test("rebasing carries the words and the speaker turns with it")
    func rebasesEverySpan() {
        let joined = JoinedStream(
            url: URL(fileURLWithPath: "/dev/null"),
            isTemporary: false,
            pieces: [.init(start: 0, offset: 0), .init(start: 2, offset: 10)]
        )

        let segment = joined.rebase(RawSegment(
            start: 2.0,
            end: 3.0,
            text: "after the seam",
            words: [TimedWord(start: 2.0, end: 2.5, text: "after")]
        ))
        #expect(segment.start == 10)
        #expect(segment.end == 11)
        #expect(segment.words?.first?.start == 10)
        #expect(segment.words?.first?.end == 10.5)

        let turn = joined.rebase(SpeakerTurn(start: 2.5, end: 4, speakerID: "speaker_1"))
        #expect(turn.start == 10.5)
        #expect(turn.end == 12)
        #expect(turn.speakerID == "speaker_1")
    }

    /// Rebasing must never hand the assembler a span that ends before it starts,
    /// however the pieces are arranged.
    @Test("rebasing is monotonic")
    func rebasingIsMonotonic() {
        let joined = JoinedStream(
            url: URL(fileURLWithPath: "/dev/null"),
            isTemporary: false,
            pieces: [
                .init(start: 0, offset: 0),
                .init(start: 2, offset: 10),
                .init(start: 5, offset: 100),
            ]
        )

        let times = stride(from: 0.0, through: 8.0, by: 0.25).map { joined.time($0) }
        #expect(zip(times, times.dropFirst()).allSatisfy { $0 < $1 })
    }
}
