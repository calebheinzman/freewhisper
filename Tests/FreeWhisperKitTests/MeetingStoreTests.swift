import Foundation
import Testing

@testable import FreeWhisperKit

@Suite("Meeting storage")
struct MeetingStoreTests {
    /// Each test gets its own root so nothing touches the user's real meetings.
    private func makeStore() -> (MeetingStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fw-tests-\(UUID().uuidString)", isDirectory: true)
        return (MeetingStore(root: root), root)
    }

    @Test("directory names sort chronologically as plain strings")
    func identifiersSortChronologically() {
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        let later = earlier.addingTimeInterval(3600)

        let first = MeetingStore.identifier(for: earlier, detectedApp: "Zoom")
        let second = MeetingStore.identifier(for: later, detectedApp: "Zoom")
        #expect(first < second)
    }

    @Test("app names are slugified into the directory name")
    func identifierIncludesSlug() {
        let id = MeetingStore.identifier(
            for: Date(timeIntervalSince1970: 1_700_000_000),
            detectedApp: "Slack Huddle"
        )
        #expect(id.hasSuffix("-slack-huddle"))
        #expect(!id.contains(":"))
        #expect(!id.contains(" "))
    }

    @Test("slugify strips punctuation and collapses separators")
    func slugify() {
        #expect("Google Meet".slugified() == "google-meet")
        #expect("Microsoft Teams (work)".slugified() == "microsoft-teams-work")
        #expect("  ".slugified() == "")
        #expect("Zoom".slugified() == "zoom")
    }

    /// The regression this guards: `.iso8601` silently truncates fractional
    /// seconds, and the sub-second gap between the two capture streams is
    /// exactly what aligns their transcripts.
    @Test("sub-second stream timestamps survive a save/load round trip")
    func fractionalSecondsRoundTrip() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let start = Date(timeIntervalSince1970: 1_700_000_000.125)
        var (metadata, _) = try store.createMeeting(startedAt: start, detectedApp: "Zoom")
        metadata.micStartedAt = start
        metadata.systemStartedAt = start.addingTimeInterval(0.038)
        try store.save(metadata)

        let loaded = try #require(store.load(id: metadata.id))
        #expect(abs(loaded.systemStreamOffset - 0.038) < 0.001)
    }

    @Test("meetings list newest first")
    func listIsNewestFirst() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try store.createMeeting(startedAt: base, detectedApp: "older")
        _ = try store.createMeeting(startedAt: base.addingTimeInterval(60), detectedApp: "newer")

        let meetings = store.list()
        #expect(meetings.count == 2)
        #expect(meetings.first?.detectedApp == "newer")
    }

    @Test("deleting a meeting removes its audio too")
    func deleteRemovesEverything() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let (metadata, paths) = try store.createMeeting(detectedApp: "Zoom")
        try Data(repeating: 0, count: 1024).write(to: paths.micAudio)
        #expect(FileManager.default.fileExists(atPath: paths.micAudio.path))

        try store.delete(id: metadata.id)
        #expect(!FileManager.default.fileExists(atPath: paths.micAudio.path))
        #expect(!FileManager.default.fileExists(atPath: paths.directory.path))
        #expect(store.load(id: metadata.id) == nil)
    }

    @Test("offset is zero when only one stream was captured")
    func offsetWithSingleStream() {
        var metadata = MeetingMetadata(id: "x", startedAt: Date())
        metadata.micStartedAt = Date()
        metadata.systemStartedAt = nil
        #expect(metadata.systemStreamOffset == 0)
    }

    @Test("display title falls back to the detected app before a summary exists")
    func displayTitleFallback() {
        var metadata = MeetingMetadata(id: "x", detectedApp: "Slack", startedAt: Date())
        #expect(metadata.displayTitle == "Slack call")

        metadata.title = "Weekly sync"
        #expect(metadata.displayTitle == "Weekly sync")
    }
}

@Suite("Meeting search")
struct MeetingSearchTests {
    private func meeting(_ id: String, title: String? = nil, app: String? = nil) -> MeetingMetadata {
        MeetingMetadata(
            id: id,
            title: title,
            detectedApp: app,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private var meetings: [MeetingMetadata] {
        [
            meeting("a", title: "Payments Migration Update", app: "Slack"),
            meeting("b", title: "Design Review", app: "Zoom"),
            meeting("c", app: "Chrome"),
        ]
    }

    private let bodies = [
        "a": "Speaker 1: the Stripe webhook handler is deployed to staging",
        "b": "Speaker 1: the new onboarding flow needs another pass",
        "c": "Speaker 1: nothing much happened here",
    ]

    private func body(_ id: String) -> String { bodies[id] ?? "" }

    @Test("an empty query returns everything")
    func emptyQueryReturnsAll() {
        #expect(MeetingSearch.filter(meetings, query: "", body: body).count == 3)
        #expect(MeetingSearch.filter(meetings, query: "   ", body: body).count == 3)
    }

    @Test("matches on title")
    func matchesTitle() {
        let results = MeetingSearch.filter(meetings, query: "design", body: body)
        #expect(results.map(\.id) == ["b"])
    }

    @Test("matches on the detected app")
    func matchesApp() {
        let results = MeetingSearch.filter(meetings, query: "slack", body: body)
        #expect(results.map(\.id) == ["a"])
    }

    /// The reason to search a meeting archive is usually to find where
    /// something was said, not to find a title.
    @Test("matches words spoken inside the transcript")
    func matchesTranscriptBody() {
        let results = MeetingSearch.filter(meetings, query: "webhook", body: body)
        #expect(results.map(\.id) == ["a"])
    }

    @Test("search is case insensitive")
    func caseInsensitive() {
        #expect(MeetingSearch.filter(meetings, query: "STRIPE", body: body).map(\.id) == ["a"])
    }

    @Test("extra words narrow the results rather than widening them")
    func multipleTermsAreConjunctive() {
        #expect(MeetingSearch.filter(meetings, query: "stripe staging", body: body).map(\.id) == ["a"])
        #expect(MeetingSearch.filter(meetings, query: "stripe onboarding", body: body).isEmpty)
    }

    @Test("no matches returns empty rather than everything")
    func noMatches() {
        #expect(MeetingSearch.filter(meetings, query: "kubernetes", body: body).isEmpty)
    }
}
