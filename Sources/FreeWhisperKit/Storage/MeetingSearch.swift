import Foundation

/// Filtering for the meetings list.
///
/// Pure and in the Kit rather than in the view model so it can be tested
/// directly. Body text is supplied by the caller, which keeps the expensive
/// part — reading transcripts off disk — cacheable at the call site.
public enum MeetingSearch {
    /// Matches against the title, the detected app, and the transcript body.
    ///
    /// Searching bodies is the point: the reason to search a meeting archive is
    /// almost always to find where something was said, not to find a title.
    ///
    /// - Parameter body: transcript and summary text for a meeting id.
    public static func filter(
        _ meetings: [MeetingMetadata],
        query: String,
        body: (String) -> String
    ) -> [MeetingMetadata] {
        let terms = query
            .lowercased()
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        guard !terms.isEmpty else { return meetings }

        return meetings.filter { meeting in
            let haystack = ([
                meeting.displayTitle,
                meeting.detectedApp ?? "",
                meeting.meetingKind ?? "",
                body(meeting.id),
            ].joined(separator: "\n")).lowercased()

            // Every term must appear somewhere, so extra words narrow the
            // results rather than widening them.
            return terms.allSatisfy { haystack.contains($0) }
        }
    }
}
