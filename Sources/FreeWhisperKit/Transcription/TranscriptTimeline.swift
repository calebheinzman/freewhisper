import Foundation

/// A meeting's transcript and its screenshots, as one ordered reading order.
///
/// Lives here rather than in the view because the Markdown export needs exactly
/// the same answer. When the two were built separately they disagreed: the
/// export split speaker runs at a screenshot and the view did not, so a
/// screenshot taken partway through a meeting rendered after a block that
/// spanned the whole call — which is what happens whenever one person does most
/// of the talking.
public enum TranscriptTimeline {
    /// A run of consecutive segments by one speaker.
    ///
    /// Grouped by display *name* rather than speaker id, which is what makes
    /// renaming two ids to the same name a working manual merge when a diarizer
    /// splits one person into several clusters.
    public struct Turn: Identifiable, Sendable, Equatable {
        /// The first segment's id — stable across recomputes, so SwiftUI keeps
        /// its scroll position instead of treating every redraw as new rows.
        public let id: UUID
        public var speakerID: String
        public var channel: TranscriptChannel
        public var start: TimeInterval
        public var end: TimeInterval
        public var texts: [String]

        public var text: String { texts.joined(separator: " ") }
    }

    public enum Entry: Identifiable, Sendable, Equatable {
        case turn(Turn)
        case screenshot(MeetingScreenshot)

        public var id: UUID {
            switch self {
            case .turn(let turn): turn.id
            case .screenshot(let screenshot): screenshot.id
            }
        }
    }

    public static func entries(
        transcript: Transcript,
        screenshots: [MeetingScreenshot] = []
    ) -> [Entry] {
        var result: [Entry] = []
        var pending = screenshots.sorted { $0.offset < $1.offset }[...]
        var current: Turn?

        func flush() {
            if let turn = current { result.append(.turn(turn)) }
            current = nil
        }

        for segment in transcript.segments {
            // A screenshot taken before this line breaks the speaker's run: the
            // next thing said needs its own heading, or it reads as a caption
            // for the image.
            while let next = pending.first, next.offset <= segment.start {
                pending = pending.dropFirst()
                flush()
                result.append(.screenshot(next))
            }

            if var last = current,
               transcript.name(for: last.speakerID) == transcript.name(for: segment.speakerID) {
                last.texts.append(segment.text)
                last.end = segment.end
                current = last
            } else {
                flush()
                current = Turn(
                    id: segment.id,
                    speakerID: segment.speakerID,
                    channel: segment.channel,
                    start: segment.start,
                    end: segment.end,
                    texts: [segment.text]
                )
            }
        }
        flush()

        // Anything captured after the last thing anyone said.
        result.append(contentsOf: pending.map(Entry.screenshot))
        return result
    }
}
