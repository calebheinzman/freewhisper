import FreeWhisperKit
import SwiftUI

/// The transcript itself, grouped into speaker turns.
struct TranscriptView: View {
    let transcript: Transcript
    var screenshots: [MeetingScreenshot] = []
    var screenshotURL: (ScreenshotImage) -> URL? = { _ in nil }
    var onDeleteScreenshot: (UUID) -> Void = { _ in }
    /// Set by the filmstrip to scroll a particular screenshot into view.
    @Binding var scrollTarget: UUID?
    let onRename: (String, String) -> Void

    @State private var renamingSpeakerID: String?
    @State private var draftName = ""

    var body: some View {
        VStack(spacing: 0) {
            speakerLegend
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(entries) { entry in
                            switch entry {
                            case .turn(let turn):
                                TurnView(
                                    turn: turn,
                                    name: transcript.name(for: turn.speakerID),
                                    onRenameTapped: { beginRename(turn.speakerID) }
                                )
                            case .screenshot(let screenshot):
                                ScreenshotCard(
                                    screenshot: screenshot,
                                    url: screenshotURL,
                                    onDelete: { onDeleteScreenshot(screenshot.id) }
                                )
                            }
                        }
                    }
                    .padding(14)
                    .textSelection(.enabled)
                }
                .onChange(of: scrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation { proxy.scrollTo(target, anchor: .top) }
                    // Reset so tapping the same thumbnail twice scrolls again.
                    scrollTarget = nil
                }
            }

            Divider()
            footer
        }
        .sheet(item: Binding(
            get: { renamingSpeakerID.map(RenameTarget.init) },
            set: { if $0 == nil { renamingSpeakerID = nil } }
        )) { target in
            renameSheet(target.speakerID)
        }
    }

    // MARK: Legend

    private var speakerLegend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(transcript.speakerIDs, id: \.self) { speakerID in
                    Button {
                        beginRename(speakerID)
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Self.color(for: speakerID))
                                .frame(width: 7, height: 7)
                            Text(transcript.name(for: speakerID))
                                .font(.system(size: 11, weight: .medium))
                            Image(systemName: "pencil")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Rename this speaker everywhere in the transcript")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private var footer: some View {
        HStack {
            Text("\(transcript.segments.count) segments · \(transcript.engine)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(transcript.plainText, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: Renaming

    private func beginRename(_ speakerID: String) {
        draftName = transcript.name(for: speakerID)
        renamingSpeakerID = speakerID
    }

    private func renameSheet(_ speakerID: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename speaker")
                .font(.headline)
            Text("Applies to every line by this speaker in this meeting.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("Name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitRename(speakerID) }

            HStack {
                Spacer()
                Button("Cancel") { renamingSpeakerID = nil }
                Button("Rename") { commitRename(speakerID) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func commitRename(_ speakerID: String) {
        onRename(speakerID, draftName)
        renamingSpeakerID = nil
    }

    // MARK: Timeline

    /// Shared with the Markdown export, so what the user reads on screen and
    /// what they get in `transcript.md` are the same reading order.
    private var entries: [TranscriptTimeline.Entry] {
        TranscriptTimeline.entries(transcript: transcript, screenshots: screenshots)
    }

    private struct RenameTarget: Identifiable {
        let speakerID: String
        var id: String { speakerID }
    }

    /// Stable per-speaker colour. "You" is always accent-coloured; everyone else
    /// gets a hue derived from their id so it stays put across reloads.
    static func color(for speakerID: String) -> Color {
        if speakerID == TranscriptAssembler.localSpeakerID { return .accentColor }
        let palette: [Color] = [.purple, .orange, .green, .pink, .teal, .indigo, .brown]
        let hash = speakerID.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xFFFF }
        return palette[hash % palette.count]
    }
}

private struct TurnView: View {
    let turn: TranscriptTimeline.Turn
    let name: String
    let onRenameTapped: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(TranscriptView.color(for: turn.speakerID))
                    .frame(width: 7, height: 7)
                Button(name, action: onRenameTapped)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                Text(Self.timestamp(turn.start))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Text(turn.text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
