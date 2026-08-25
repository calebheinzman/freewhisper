import FreeWhisperKit
import SwiftUI

struct MeetingsWindow: View {
    @State private var model = MeetingsModel.shared
    /// Set by the filmstrip, consumed by the transcript's ScrollViewReader.
    @State private var scrollTarget: UUID?
    @AppStorage(SettingsKeys.transcriptionModel) private var modelID = ModelCatalog.defaultTranscriber.id

    private var transcriptionModel: ModelCatalog.Model {
        ModelCatalog.transcriber(id: modelID, or: ModelCatalog.defaultTranscriber)
    }

    var body: some View {
        // @Observable held in @State needs a local @Bindable before its
        // properties can be projected into bindings.
        @Bindable var model = model

        NavigationSplitView {
            sidebar(model: model)
        } detail: {
            detail
        }
        .frame(minWidth: 760, minHeight: 460)
        .onAppear { model.reload() }
    }

    // MARK: Sidebar

    /// Explicit row buttons rather than `List(selection:)`. The binding-based
    /// selection did not track clicks reliably here, and owning the tap handler
    /// makes the behaviour obvious rather than dependent on how SwiftUI derives
    /// tags for the row content.
    private func sidebar(model: MeetingsModel) -> some View {
        List {
            ForEach(model.meetings) { meeting in
                MeetingRow(
                    meeting: meeting,
                    isSelected: model.selectedID == meeting.id,
                    onSelect: { model.selectedID = meeting.id }
                )
                .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                .contextMenu {
                    Button("Show in Finder") { model.revealInFinder(id: meeting.id) }
                    Divider()
                    Button("Delete", role: .destructive) { model.delete(id: meeting.id) }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 240, ideal: 270)
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search transcripts")
        .overlay {
            if model.meetings.isEmpty {
                ContentUnavailableView(
                    "No recordings yet",
                    systemImage: "waveform",
                    description: Text("Start one from the menu bar, or let FreeWhisper detect your next call.")
                )
            } else if model.filteredMeetings.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let meeting = model.selected {
            VStack(alignment: .leading, spacing: 0) {
                detailHeader(meeting)
                Divider()

                if let error = model.error {
                    ErrorRow(text: error)
                }
                // Capture problems are recorded on the meeting itself; showing
                // them here is what stops a half-captured call from silently
                // reading as a complete one.
                if let micError = meeting.micError {
                    WarningRow(text: micError)
                }
                if let systemError = meeting.systemAudioError {
                    WarningRow(text: systemError)
                }

                if let transcript = model.transcript, !transcript.isEmpty {
                    if let summary = model.summary {
                        SummaryCard(summary: summary)
                    }
                    if !model.screenshots.isEmpty {
                        ScreenshotStrip(
                            screenshots: model.screenshots,
                            url: { model.url(for: $0) },
                            onSelect: { scrollTarget = $0.id }
                        )
                        Divider()
                    }
                    TranscriptView(
                        transcript: transcript,
                        screenshots: model.screenshots,
                        screenshotURL: { model.url(for: $0) },
                        onDeleteScreenshot: { model.deleteScreenshot(id: $0) },
                        scrollTarget: $scrollTarget,
                        onRename: { speakerID, name in
                            model.rename(speakerID: speakerID, to: name)
                        }
                    )
                } else {
                    // Screenshots exist the moment the call ends; the transcript
                    // doesn't. Showing them here means a user can check what they
                    // captured without waiting on Whisper.
                    if !model.screenshots.isEmpty {
                        ScreenshotStrip(
                            screenshots: model.screenshots,
                            url: { model.url(for: $0) },
                            onSelect: { screenshot in
                                guard let image = screenshot.images.first,
                                      let url = model.url(for: image) else { return }
                                NSWorkspace.shared.open(url)
                            }
                        )
                        Divider()
                    }
                    emptyTranscriptState(meeting)
                }
            }
        } else {
            ContentUnavailableView("Select a recording", systemImage: "doc.text")
        }
    }

    private func detailHeader(_ meeting: MeetingMetadata) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.displayTitle)
                    .font(.system(size: 17, weight: .semibold))
                Text(meeting.startedAt, format: .dateTime.weekday(.wide).month().day().hour().minute())
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if model.isWorking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(model.progressText ?? "Working…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 8) {
                    if model.transcript != nil {
                        Button(model.summary == nil ? "Summarize" : "Re-summarize") {
                            Task { await model.summarize() }
                        }
                    }
                    Button(model.transcript == nil ? "Transcribe" : "Re-transcribe") {
                        Task { await model.transcribe(model: transcriptionModel) }
                    }
                }
                .controlSize(.regular)
            }
        }
        .padding(14)
    }

    private func emptyTranscriptState(_ meeting: MeetingMetadata) -> some View {
        ContentUnavailableView {
            Label("No transcript yet", systemImage: "text.bubble")
        } description: {
            Text("Transcribe with \(transcriptionModel.name). The first run downloads it.")
        } actions: {
            if !model.isWorking {
                Button("Transcribe") {
                    Task { await model.transcribe(model: transcriptionModel) }
                }
            }
        }
    }

    // MARK: Formatting

    private static func durationText(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        if total >= 3600 {
            return String(format: "%dh %dm", total / 3600, (total % 3600) / 60)
        }
        if total >= 60 {
            return String(format: "%dm %ds", total / 60, total % 60)
        }
        return "\(total)s"
    }

    private static func statusText(_ status: MeetingStatus) -> String {
        switch status {
        case .recording: "recording"
        case .awaitingTranscription: "not transcribed"
        case .transcribing: "transcribing"
        case .summarizing: "summarizing"
        case .complete: "done"
        case .failed: "failed"
        }
    }
}

private struct WarningRow: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11))
            .foregroundStyle(.orange)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08))
    }
}

private struct ErrorRow: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "xmark.octagon.fill")
            .font(.system(size: 11))
            .foregroundStyle(.red)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08))
    }
}

private struct MeetingRow: View {
    let meeting: MeetingMetadata
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(meeting.startedAt, format: .dateTime.month().day().hour().minute())
                    Text("·")
                    Text(Self.durationText(meeting.duration))
                    if meeting.status != .complete {
                        Text("·")
                        Text(Self.statusText(meeting.status))
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private static func durationText(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        if total >= 3600 { return String(format: "%dh %dm", total / 3600, (total % 3600) / 60) }
        if total >= 60 { return String(format: "%dm %ds", total / 60, total % 60) }
        return "\(total)s"
    }

    private static func statusText(_ status: MeetingStatus) -> String {
        switch status {
        case .recording: "recording"
        case .awaitingTranscription: "not transcribed"
        case .transcribing: "transcribing"
        case .summarizing: "summarizing"
        case .complete: "done"
        case .failed: "failed"
        }
    }
}


/// The generated summary, above the transcript.
///
/// Rendered from the structured summary rather than from summary.md — showing
/// a user raw "## Key points" and "- [ ]" is showing them the plumbing.
private struct SummaryCard: View {
    let summary: MeetingSummary
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if !summary.summary.isEmpty {
                            Text(summary.summary)
                                .font(.system(size: 12))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        bulletList("Key points", summary.keyPoints, symbol: "circle.fill")
                        bulletList("Action items", summary.actionItems, symbol: "square")
                        if !summary.tags.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(summary.tags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.system(size: 9))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.primary.opacity(0.07), in: Capsule())
                                }
                            }
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
                .frame(maxHeight: 240)
            }
        }
        .background(Color.accentColor.opacity(0.05))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Summary")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(summary.markdown, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .help("Copy as Markdown")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func bulletList(_ title: String, _ items: [String], symbol: String) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: symbol)
                            .font(.system(size: symbol == "square" ? 9 : 4))
                            .foregroundStyle(.secondary)
                        Text(item)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
