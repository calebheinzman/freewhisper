import AVFoundation
import Foundation

/// One capture stream, reassembled from the pieces it was written in.
///
/// A stream that was restarted mid-meeting is several files. Transcribing only
/// the first one silently drops the rest of the call, which is exactly what used
/// to happen — an 88-minute meeting whose microphone died at 43 minutes read as
/// a 42-minute transcript, and the ten minutes of remote audio that capture did
/// recover after the restart were never looked at.
///
/// The pieces are joined end to end rather than laid out on a padded timeline.
/// Padding the gaps with silence would put the samples at their true offsets and
/// need no mapping at all, but it also hands the engine every dead minute to
/// transcribe — and Whisper answers silence with invented text. Joining keeps
/// the audio to what was actually captured and rebases the timestamps
/// afterwards.
struct JoinedStream {
    let url: URL
    /// False when the stream was a single unbroken file and this is the
    /// recording itself, which must not be deleted.
    let isTemporary: Bool
    /// Where each piece starts in the joined file, and where it belongs on the
    /// stream's own clock.
    let pieces: [Piece]

    struct Piece: Equatable {
        /// Seconds from the start of the joined file.
        let start: TimeInterval
        /// Seconds from the moment the stream opened.
        let offset: TimeInterval
    }

    /// Puts a timestamp from the joined file back onto the stream's clock.
    ///
    /// A span that crosses a seam is stretched across the gap it spans, because
    /// that is where it really sits: the words before the seam were said before
    /// capture died and the words after it long afterwards. The mapping is
    /// monotonic — each piece was captured after the last one ended — so a
    /// segment can never come back inverted.
    func time(_ joined: TimeInterval) -> TimeInterval {
        var piece = pieces.first ?? Piece(start: 0, offset: 0)
        for candidate in pieces where candidate.start <= joined {
            piece = candidate
        }
        return piece.offset + (joined - piece.start)
    }

    func rebase(_ segment: RawSegment) -> RawSegment {
        RawSegment(
            start: time(segment.start),
            end: time(segment.end),
            text: segment.text,
            words: segment.words?.map {
                TimedWord(start: time($0.start), end: time($0.end), text: $0.text)
            }
        )
    }

    func rebase(_ turn: SpeakerTurn) -> SpeakerTurn {
        SpeakerTurn(start: time(turn.start), end: time(turn.end), speakerID: turn.speakerID)
    }

    func cleanUp() {
        guard isTemporary else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

enum StreamJoiner {
    /// Joins the pieces of one stream, or hands back the single file untouched.
    ///
    /// Returns nil when the stream captured nothing at all, which is the normal
    /// answer for a meeting recorded without a microphone.
    static func join(_ segments: [AudioSegment]) throws -> JoinedStream? {
        let existing = segments.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        guard let first = existing.first else { return nil }

        // The overwhelmingly common case: capture never broke, so there is
        // nothing to join and no temporary file to write or clean up.
        if existing.count == 1, first.offset == 0 {
            return JoinedStream(
                url: first.url,
                isTemporary: false,
                pieces: [.init(start: 0, offset: 0)]
            )
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fw-joined-\(UUID().uuidString).wav")
        let file = try AudioLoader.makeFile(at: url)

        var pieces: [JoinedStream.Piece] = []
        var start: TimeInterval = 0
        for segment in existing {
            // One piece in memory at a time. A long meeting's samples are
            // hundreds of megabytes and there is no reason to hold them all.
            let samples = try AudioLoader.loadSamples(from: segment.url)
            guard !samples.isEmpty else { continue }

            pieces.append(.init(start: start, offset: segment.offset))
            try AudioLoader.append(samples, to: file)
            start += Double(samples.count) / AudioFormats.sampleRate
        }

        guard !pieces.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }

        Log.transcription.info("""
            joined \(pieces.count, privacy: .public) pieces of \
            \(first.url.lastPathComponent, privacy: .public) into \
            \(Int(start), privacy: .public)s
            """)
        return JoinedStream(url: url, isTemporary: true, pieces: pieces)
    }
}
