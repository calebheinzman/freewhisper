import AppKit
import Foundation
import FreeWhisperKit
import Observation

/// Backing state for the Meetings window.
@Observable
@MainActor
final class MeetingsModel {
    /// Shared so a deep link handled by the menu bar scene and the Meetings
    /// window are talking to the same object. App-level @State does not
    /// reliably propagate across SwiftUI scenes.
    static let shared = MeetingsModel()

    private(set) var meetings: [MeetingMetadata] = []
    private(set) var transcript: Transcript?
    private(set) var summary: MeetingSummary?
    private(set) var screenshots: [MeetingScreenshot] = []
    private(set) var isWorking = false
    private(set) var progressText: String?
    private(set) var error: String?

    /// Free-text filter over titles, summaries and transcript bodies.
    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            rebuildFilter()
        }
    }

    private(set) var filteredMeetings: [MeetingMetadata] = []

    var selectedID: String? {
        didSet {
            guard selectedID != oldValue else { return }
            loadTranscript()
        }
    }

    @ObservationIgnored private let store = MeetingStore.shared
    @ObservationIgnored private let screenshotStore = ScreenshotStore.shared
    @ObservationIgnored private lazy var pipeline = TranscriptionPipeline(store: store)

    var selected: MeetingMetadata? {
        guard let selectedID else { return nil }
        return meetings.first { $0.id == selectedID }
    }

    func reload() {
        meetings = store.list()
        rebuildFilter()
        if selectedID == nil || !meetings.contains(where: { $0.id == selectedID }) {
            selectedID = filteredMeetings.first?.id ?? meetings.first?.id
        }
    }

    /// Searches the transcript text too, not just titles — the reason to search
    /// a meeting archive is usually to find who said a particular thing.
    private func rebuildFilter() {
        filteredMeetings = MeetingSearch.filter(
            meetings,
            query: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
            body: { [weak self] id in self?.searchIndex(for: id) ?? "" }
        )
    }

    /// Transcript and summary text, cached per meeting. Re-reading every
    /// transcript on each keystroke would make search unusable once there are a
    /// few hundred meetings.
    @ObservationIgnored private var searchIndexCache: [String: String] = [:]

    private func searchIndex(for id: String) -> String {
        if let cached = searchIndexCache[id] { return cached }

        var text = pipeline.loadTranscript(meetingID: id)?.plainText ?? ""
        if let summary = pipeline.loadSummary(meetingID: id) {
            text += "\n" + summary.summary + "\n" + summary.keyPoints.joined(separator: "\n")
        }
        searchIndexCache[id] = text
        return text
    }

    private func invalidateSearchIndex(for id: String) {
        searchIndexCache[id] = nil
    }

    /// Select a meeting by id, reloading first so a just-finished recording is
    /// selectable. No-op if the id is unknown.
    func select(id: String) {
        if !meetings.contains(where: { $0.id == id }) {
            meetings = store.list()
        }
        guard meetings.contains(where: { $0.id == id }) else {
            Log.app.error("deep link: unknown meeting \(id, privacy: .public)")
            return
        }
        selectedID = id
    }

    private func loadTranscript() {
        error = nil
        guard let selectedID else {
            transcript = nil
            summary = nil
            screenshots = []
            return
        }
        transcript = pipeline.loadTranscript(meetingID: selectedID)
        summary = pipeline.loadSummary(meetingID: selectedID)
        screenshots = screenshotStore.load(meetingID: selectedID)
    }

    /// Called when a screenshot is taken, so the window updates live if it
    /// happens to be showing the meeting being recorded.
    func screenshotsChanged(meetingID: String) {
        guard selectedID == meetingID else { return }
        screenshots = screenshotStore.load(meetingID: meetingID)
    }

    func url(for image: ScreenshotImage) -> URL? {
        guard let selectedID else { return nil }
        return screenshotStore.url(for: image, meetingID: selectedID)
    }

    func deleteScreenshot(id: UUID) {
        guard let selectedID else { return }
        do {
            try screenshotStore.delete(id: id, meetingID: selectedID)
            screenshots = screenshotStore.load(meetingID: selectedID)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Actions

    func transcribe(model: ModelCatalog.Model) async {
        guard let id = selectedID, !isWorking else { return }
        isWorking = true
        error = nil
        progressText = "Preparing…"

        do {
            let result = try await pipeline.run(meetingID: id, model: model) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.progressText = Self.describe(progress)
                }
            }
            transcript = result
            invalidateSearchIndex(for: id)
        } catch {
            self.error = error.localizedDescription
            Log.transcription.error("transcription failed: \(error.localizedDescription, privacy: .public)")
        }

        isWorking = false
        progressText = nil
        reload()
    }

    func summarize() async {
        guard let id = selectedID, !isWorking else { return }
        isWorking = true
        error = nil
        progressText = "Summarizing…"

        do {
            _ = try await pipeline.summarize(meetingID: id) { [weak self] step in
                Task { @MainActor [weak self] in self?.progressText = step }
            }
            summary = pipeline.loadSummary(meetingID: id)
            invalidateSearchIndex(for: id)
        } catch {
            self.error = error.localizedDescription
        }

        isWorking = false
        progressText = nil
        reload()
    }

    func rename(speakerID: String, to name: String) {
        guard let id = selectedID else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            transcript = try pipeline.rename(speakerID: speakerID, to: trimmed, meetingID: id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func delete(id: String) {
        do {
            try store.delete(id: id)
            if selectedID == id { selectedID = nil }
            reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func revealInFinder(id: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: store.paths(for: id).directory.path)
    }

    private static func describe(_ progress: EngineProgress) -> String {
        switch progress {
        case .downloadingModel(let name, let fraction):
            if let fraction {
                return "Downloading \(name) — \(Int(fraction * 100))%"
            }
            return "Preparing \(name)…"
        case .loadingModel(let name):
            return "Loading \(name)…"
        case .transcribing:
            return "Transcribing…"
        case .diarizing:
            return "Identifying speakers…"
        }
    }
}
