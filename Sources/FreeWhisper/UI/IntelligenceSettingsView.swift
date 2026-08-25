import FreeWhisperKit
import SwiftUI

/// The three models the app runs, named by what they do.
///
/// These were engine pickers — "WhisperKit (Whisper)", "FluidAudio (Parakeet)"
/// — with a separate Models section listing weights under the same SDK names.
/// Both halves were wrong: those are the names of our dependencies, and nothing
/// on screen said which of the three things the app does with speech they
/// affected. So the sections are named for the roles, and each row *is* its own
/// download row — the model you select is the model you download, in the same
/// place, which is the only arrangement where "where did this come from" has an
/// obvious answer.
struct IntelligenceSettingsView: View {
    @Bindable private var models = ModelSetupModel.shared

    @AppStorage(SettingsKeys.transcriptionModel)
    private var transcriptionModelID = ModelCatalog.defaultTranscriber.id
    @AppStorage(SettingsKeys.dictationModel)
    private var dictationModelID = ModelCatalog.defaultDictationTranscriber.id
    @AppStorage(SettingsKeys.autoTranscribe) private var autoTranscribe = true

    @State private var transcriptionProvider = LLMSettings.transcriptionProvider
    @State private var summaryProvider = LLMSettings.current
    @State private var summariesEnabled = LLMSettings.summarizationEnabled

    var body: some View {
        Form {
            transcriptionSection
            dictationSection
            summarySection
            storageSection
        }
        .formStyle(.grouped)
        .onAppear { models.refresh() }
    }

    private var transcriptionModel: ModelCatalog.Model {
        ModelCatalog.transcriber(id: transcriptionModelID, or: ModelCatalog.defaultTranscriber)
    }

    private var dictationModel: ModelCatalog.Model {
        ModelCatalog.transcriber(id: dictationModelID, or: ModelCatalog.defaultDictationTranscriber)
    }

    // MARK: Transcription

    @ViewBuilder
    private var transcriptionSection: some View {
        Section {
            speechModels(selection: $transcriptionModelID, showsCloudSettings: true)

            // Only meetings are diarized, so the diarizer belongs here and
            // nowhere else. Labelled rather than merely separated: an unlabelled
            // divider leaves it looking like a seventh thing you could pick.
            caption("SPEAKER LABELS")
                .padding(.top, 4)
            modelRow(ModelCatalog.diarizer(for: transcriptionModel.engine ?? .whisperKit), onSelect: nil)

            Toggle("Transcribe automatically when a recording ends", isOn: $autoTranscribe)
        } header: {
            Text("Transcription Model")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                caption("Used for meeting recordings. Transcription runs after the call rather than during it, so it doesn't compete with the meeting for CPU.")
                privacyNote(for: transcriptionModel)
            }
        }
    }

    // MARK: Voice to text

    @ViewBuilder
    private var dictationSection: some View {
        Section {
            // If meetings are already on cloud, the endpoint fields are up
            // there and there is only one cloud configuration — showing a
            // second copy of the same three fields would invite the reader to
            // think they were independent.
            speechModels(
                selection: $dictationModelID,
                showsCloudSettings: !transcriptionModel.isWeightless
            )
        } header: {
            Text("Voice to Text Model")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                caption("Used for the ⌘⎋ dictation hotkey. Defaults to Parakeet even when meetings use Whisper: here the text needs to land the moment you stop talking.")
                privacyNote(for: dictationModel)
            }
        }
    }

    /// The shared list of speech models, used by both speech roles.
    ///
    /// One list rather than two, because a model downloaded for meetings is the
    /// same file dictation would use — `ModelSetupModel` is keyed on model id,
    /// so a download started in one section shows as ready in the other.
    @ViewBuilder
    private func speechModels(selection: Binding<String>, showsCloudSettings: Bool) -> some View {
        ForEach(ModelCatalog.transcribers) { model in
            modelRow(
                model,
                isSelected: selection.wrappedValue == model.id,
                onSelect: { select(model, into: selection) }
            )
        }

        // Outside the ForEach, not inside it. A conditional row emitted from a
        // ForEach body renders wrongly in a grouped Form — the selected row
        // disappears and the first field below it is drawn twice.
        if selection.wrappedValue == ModelCatalog.cloudTranscription.id {
            if showsCloudSettings {
                cloudSettings
            } else {
                caption("Uses the cloud settings above.")
            }
        }
    }

    @ViewBuilder
    private var cloudSettings: some View {
        Picker("Provider", selection: presetBinding(
            for: $transcriptionProvider,
            presets: LLMProvider.transcriptionPresets,
            persist: { LLMSettings.transcriptionProvider = $0 }
        )) {
            ForEach(LLMProvider.transcriptionPresets, id: \.name) { preset in
                Text(preset.name).tag(preset.name)
            }
        }

        EndpointFields(
            provider: $transcriptionProvider,
            persist: { LLMSettings.transcriptionProvider = transcriptionProvider },
            test: { try await AudioTranscriptionClient(provider: $0).testConnection() }
        )
        // Re-create on a preset change so the key field reloads from the new
        // provider's Keychain entry rather than showing the previous one's.
        .id(transcriptionProvider.name)
    }

    /// Selecting a model that isn't here yet starts fetching it.
    ///
    /// The size is on the row before it is clicked, so this is not a surprise —
    /// and it is what the app already does everywhere else. Lazily, the
    /// download would instead begin the moment the user's first real meeting
    /// ended, which is the worst possible time for it to fail.
    private func select(_ model: ModelCatalog.Model, into selection: Binding<String>) {
        selection.wrappedValue = model.id
        guard !model.isWeightless, models.state(model) == .missing else { return }
        Task { await models.download(model) }
    }

    /// Sending a meeting's audio to a third party is a bigger step than sending
    /// its text, so this says so in more words than the summary note does.
    @ViewBuilder
    private func privacyNote(for model: ModelCatalog.Model) -> some View {
        if model.isWeightless {
            Label(
                "Recordings are uploaded to \(transcriptionProvider.name) to be transcribed. "
                    + "Speaker labels are still worked out on this Mac.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.system(size: 10))
            .foregroundStyle(.orange)
        } else {
            Label("Runs entirely on this Mac.", systemImage: "lock.fill")
                .font(.system(size: 10))
                .foregroundStyle(.green)
        }
    }

    // MARK: Summaries

    @ViewBuilder
    private var summarySection: some View {
        Section {
            Toggle("Summarize meetings automatically", isOn: $summariesEnabled)
                .onChange(of: summariesEnabled) { _, value in
                    LLMSettings.summarizationEnabled = value
                }

            // Built-in weights and third-party endpoints in one list, in the
            // same shape as the two sections above: from the user's side these
            // are alternatives to each other, not two different kinds of thing.
            ForEach(builtInSummarizers) { model in
                modelRow(
                    model,
                    isSelected: isSelectedSummarizer(model),
                    onSelect: { selectSummarizer(model) }
                )
            }

            ForEach(endpointSummaryPresets, id: \.name) { preset in
                providerRow(preset)
            }

            // See the note in `speechModels`: this has to sit outside the
            // ForEach that produced the row it belongs to.
            if summaryProvider.resolvedBackend != .onDevice {
                EndpointFields(
                    provider: $summaryProvider,
                    persist: { LLMSettings.current = summaryProvider },
                    test: { _ = try await ChatClient.make(for: $0).testConnection() }
                )
                .id(summaryProvider.name)
            }
        } header: {
            Text("Summary Model")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                caption("Used for meeting summaries and their action items.")
                summaryPrivacyNote
            }
        }
    }

    /// Intel Macs cannot run MLX, so offering the built-in models there would
    /// be offering something that can only fail.
    private var builtInSummarizers: [ModelCatalog.Model] {
        LocalLLMEngine.isSupported ? ModelCatalog.summarizers : []
    }

    private var endpointSummaryPresets: [LLMProvider] {
        LLMProvider.presets.filter { $0.resolvedBackend != .onDevice }
    }

    private func isSelectedSummarizer(_ model: ModelCatalog.Model) -> Bool {
        summaryProvider.resolvedBackend == .onDevice && summaryProvider.model == model.id
    }

    private func selectSummarizer(_ model: ModelCatalog.Model) {
        var provider = LLMProvider.onDevice
        provider.model = model.id
        summaryProvider = provider
        LLMSettings.current = provider

        guard models.state(model) == .missing else { return }
        Task { await models.download(model) }
    }

    private func providerRow(_ preset: LLMProvider) -> some View {
        let isSelected = summaryProvider.resolvedBackend != .onDevice
            && summaryProvider.name == preset.name

        return SelectableRow(
            title: preset.name,
            subtitle: Self.describe(preset),
            isSelected: isSelected,
            onSelect: {
                summaryProvider = preset
                LLMSettings.current = preset
            }
        )
    }

    /// "Transcripts are sent to Custom" is not a sentence about anything, so
    /// the catch-all preset describes what it is instead of naming itself.
    private static func describe(_ preset: LLMProvider) -> String {
        if preset.isLocal { return "A server you run yourself. Nothing leaves this Mac." }
        if preset.name == "Custom" { return "Any other endpoint speaking the OpenAI API shape." }
        return "Your own key. Transcripts are sent to \(preset.name)."
    }

    @ViewBuilder
    private var summaryPrivacyNote: some View {
        if summariesEnabled {
            if summaryProvider.isLocal {
                Label("Runs on this Mac. Transcripts never leave it.", systemImage: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
            } else {
                Label(
                    "Meeting transcripts are sent to \(summaryProvider.name) to be summarized. Audio never is.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            }
        } else {
            caption("Off means transcripts are still produced, but never sent to a model.")
        }
    }

    // MARK: Storage

    private var storageSection: some View {
        Section("Storage") {
            LabeledContent("Models on disk", value: byteText(models.bytesOnDisk))
            LabeledContent("Recordings", value: byteText(MeetingStore.shared.totalBytesOnDisk()))
            LabeledContent("Show in Finder") {
                HStack(spacing: 10) {
                    Button("Models") {
                        guard let first = ModelCatalog.cacheDirectories().first else { return }
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: first.path)
                    }
                    Button("Recordings") {
                        NSWorkspace.shared.selectFile(
                            nil,
                            inFileViewerRootedAtPath: MeetingStore.shared.root.path
                        )
                    }
                }
            }
        }
    }

    // MARK: Shared

    private func modelRow(
        _ model: ModelCatalog.Model,
        isSelected: Bool = false,
        onSelect: (() -> Void)?
    ) -> some View {
        ModelRow(
            model: model,
            state: models.state(model),
            isSelected: isSelected,
            onSelect: onSelect,
            onDownload: { Task { await models.download(model) } },
            onRemove: { models.remove(model) }
        )
    }

    /// Swapping a preset replaces the whole provider rather than editing it in
    /// place, so the endpoint, model and key all move together.
    private func presetBinding(
        for provider: Binding<LLMProvider>,
        presets: [LLMProvider],
        persist: @escaping (LLMProvider) -> Void
    ) -> Binding<String> {
        Binding(
            get: { provider.wrappedValue.name },
            set: { name in
                guard let preset = presets.first(where: { $0.name == name }) else { return }
                provider.wrappedValue = preset
                persist(preset)
            }
        )
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Shared pieces

/// Endpoint, model, key and a live connection test.
///
/// Shared between cloud transcription and BYOK summarization: the two features
/// send very different payloads, but from the user's side configuring them is
/// the same three fields and the same question — does this work?
///
/// The provider choice stays with the caller, which needs one whether or not
/// these fields are showing.
private struct EndpointFields: View {
    @Binding var provider: LLMProvider
    let persist: () -> Void
    let test: @Sendable (LLMProvider) async throws -> Void

    @State private var apiKey = ""
    @State private var isTesting = false
    @State private var result: TestResult?

    private enum TestResult {
        case success
        case failure(String)
    }

    var body: some View {
        Group {
            TextField("Endpoint", text: $provider.baseURL)
                .textFieldStyle(.roundedBorder)
                .onChange(of: provider.baseURL) { _, _ in persist() }

            TextField("Model", text: $provider.model)
                .textFieldStyle(.roundedBorder)
                .onChange(of: provider.model) { _, _ in persist() }

            if provider.keychainAccount != nil {
                SecureField("API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { provider.setAPIKey(apiKey) }
                    .onChange(of: apiKey) { _, _ in provider.setAPIKey(apiKey) }
            }

            HStack {
                Button("Test connection") { runTest() }
                    .disabled(isTesting)
                if isTesting {
                    ProgressView().controlSize(.small)
                }
                switch result {
                case .success:
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 11))
                case .failure(let message):
                    Label(message, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 11))
                        .lineLimit(2)
                case nil:
                    EmptyView()
                }
            }
        }
        .onAppear { apiKey = provider.apiKey ?? "" }
    }

    private func runTest() {
        isTesting = true
        result = nil
        let provider = self.provider
        let test = self.test

        Task {
            do {
                try await test(provider)
                result = .success
            } catch {
                result = .failure(error.localizedDescription)
            }
            isTesting = false
        }
    }
}

/// A model, its download state, and — where there is a choice — the control
/// that selects it. One row rather than a picker entry plus a list entry
/// somewhere else, which is the whole point of the rearrangement.
///
/// `onSelect` is nil for models the user doesn't choose, like the diarizer.
private struct ModelRow: View {
    let model: ModelCatalog.Model
    let state: ModelSetupModel.State
    let isSelected: Bool
    let onSelect: (() -> Void)?
    let onDownload: () -> Void
    let onRemove: () -> Void

    @State private var isConfirmingRemove = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            label
            Spacer(minLength: 4)
            action
        }
        .padding(.vertical, 2)
        .confirmationDialog(
            "Remove \(model.name)?",
            isPresented: $isConfirmingRemove,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive, action: onRemove)
        } message: {
            Text(isSelected
                ? "This model is selected. It will be downloaded again next time it's needed."
                : "Frees \(model.approximateSize). You can download it again later.")
        }
    }

    @ViewBuilder
    private var label: some View {
        if let onSelect {
            Button(action: onSelect) { rowContent }
                .buttonStyle(.plain)
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 8) {
            marker
                .frame(width: 16)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(isFailed ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if case .downloading(let fraction) = state {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .frame(maxWidth: 220)
                }
            }
        }
        // Without this the row is only clickable on the glyph and the text,
        // and the gaps between them silently do nothing.
        .contentShape(Rectangle())
    }

    /// A radio for anything selectable; otherwise the download state, since
    /// that is the only thing left for the glyph to say.
    @ViewBuilder
    private var marker: some View {
        if onSelect != nil {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        } else {
            statusIcon
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch state {
        case .ready:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .downloading:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .missing:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var action: some View {
        // Nothing to download and nothing to reclaim.
        if model.isWeightless {
            EmptyView()
        } else {
            switch state {
            case .ready:
                Button("Remove") { isConfirmingRemove = true }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            case .missing:
                Button("Download", action: onDownload)
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
            case .failed:
                Button("Retry", action: onDownload)
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
            case .downloading:
                EmptyView()
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private var subtitle: String {
        switch state {
        case .failed(let message):
            message
        case .downloading(let fraction):
            "\(model.detail) · downloading \(Int(fraction * 100))%"
        default:
            model.isWeightless ? model.detail : "\(model.detail) · \(model.approximateSize)"
        }
    }
}

/// A selectable row with no weights behind it, for the summarization endpoints.
private struct SelectableRow: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 16)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}
