import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage("transcriptFontSize") private var transcriptFontSize = TranscriptFontSize.normal.rawValue
    @AppStorage("modelPath") private var modelPath = ""
    @AppStorage("targetLanguage") private var targetLanguage = ""
    @AppStorage("translationEndpoint") private var translationEndpoint = ""
    @AppStorage("translationAPIKey") private var translationAPIKey = ""
    @AppStorage("translationModel") private var translationModel = ""

    @AppStorage(DiarizationService.useRemoteKey) private var diarizationUseRemote = false
    /// The voice library has no observable store, so the list is snapshotted when
    /// Settings opens and kept in step as the user deletes from it.
    @State private var knownSpeakers: [SpeakerProfile] = []

    // Local OpenAI-compatible API server
    @AppStorage(APIServer.enabledKey) private var apiServerEnabled = false
    @AppStorage(APIServer.portKey) private var apiServerPort = 8080
    @AppStorage(APIServer.tokenKey) private var apiServerToken = ""
    @AppStorage(APIServer.allowLANKey) private var apiServerAllowLAN = false
    @AppStorage(APIServer.verboseLogKey) private var apiServerVerboseLog = false
    @State private var apiServer = APIServer.shared

    @State private var verifyInFlight = false
    @State private var verifyResult: VerifyResult? = nil

    // Backup & restore
    @State private var backupStatus: BackupStatus? = nil
    @State private var pendingRestore: BackupService.BackupFile? = nil
    @State private var showRestoreConfirm = false

    // Meeting minutes
    @State private var minutesStore = MinutesPromptStore.shared
    @AppStorage(MinutesPromptStore.contextTokensKey) private var minutesContextTokens = MinutesPromptStore.defaultContextTokens
    @State private var editingPrompt: MinutesPrompt? = nil
    @State private var promptPendingDelete: MinutesPrompt? = nil

    private enum VerifyResult {
        case success(String)
        case failure(String)
    }

    private enum BackupStatus {
        case success(String)
        case failure(String)
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Transcript Font Size", selection: $transcriptFontSize) {
                    ForEach(TranscriptFontSize.allCases, id: \.rawValue) { size in
                        Text(size.label).tag(size.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Translation") {
                Picker("Target Language", selection: $targetLanguage) {
                    Text("Off").tag("")
                    ForEach(TargetLanguage.available) { lang in
                        Text(lang.nativeName).tag(lang.id)
                    }
                }
                Text("Translate live transcription to this language using an OpenAI-compatible API configured below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("OpenAI API") {
                TextField("API Endpoint", text: $translationEndpoint,
                          prompt: Text("https://api.openai.com/v1"))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: translationEndpoint) { _, _ in verifyResult = nil }
                SecureField("API Key", text: $translationAPIKey,
                            prompt: Text("sk-..."))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: translationAPIKey) { _, _ in verifyResult = nil }
                TextField("Model", text: $translationModel,
                          prompt: Text("gpt-4o-mini"))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: translationModel) { _, _ in verifyResult = nil }
                Text("Used for translation and meeting minutes. Only API Key is required. Endpoint defaults to OpenAI, model defaults to gpt-4o-mini.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button {
                        verifyConnection()
                    } label: {
                        if verifyInFlight {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Verify Connection")
                        }
                    }
                    .disabled(verifyInFlight || translationAPIKey.trimmingCharacters(in: .whitespaces).isEmpty)

                    switch verifyResult {
                    case .success(let msg):
                        Label(msg, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    case .failure(let msg):
                        Label(msg, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                            .lineLimit(2)
                    case .none:
                        EmptyView()
                    }
                    Spacer()
                }
            }

            Section("Meeting Minutes") {
                ForEach(minutesStore.prompts) { prompt in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(prompt.name)
                            Text(prompt.prompt)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button {
                            editingPrompt = prompt
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .help("Edit prompt")

                        Button {
                            promptPendingDelete = prompt
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(minutesStore.prompts.count == 1)
                        .help(minutesStore.prompts.count == 1
                              ? "The last prompt can't be deleted" : "Delete prompt")
                    }
                }

                Button("Add Prompt…") {
                    editingPrompt = MinutesPrompt(name: "", prompt: "")
                }

                HStack {
                    Text("Model context window")
                    Spacer()
                    TextField("16000", value: $minutesContextTokens, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                        .textFieldStyle(.roundedBorder)
                    Text("tokens")
                        .foregroundStyle(.secondary)
                }

                Text("Prompts appear in the Meeting Minutes menu above the transcript. Transcripts longer than the context window are summarized in chunks first, then combined into the minutes. Uses the OpenAI API configured above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Speakers") {
                Picker("Diarization Engine", selection: $diarizationUseRemote) {
                    Text("On-device").tag(false)
                    Text("OpenAI").tag(true)
                }
                .pickerStyle(.segmented)
                Text(diarizationUseRemote
                     ? "Uploads the recording to OpenAI's gpt-4o-transcribe-diarize (25 MB limit, at most 4 known voices per run) using the API key above. More accurate on crowded conversations."
                     : "Identifies speakers entirely on this Mac using the Neural Engine. No key, no upload; the models download on first use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if knownSpeakers.isEmpty {
                    Text("No known voices yet. Name the speakers on a transcript and the app keeps a short clip of each one to recognize them next time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(knownSpeakers) { speaker in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Color(nsColor: NSColor(hexString: speaker.colorHex) ?? .systemGray))
                                .frame(width: 10, height: 10)
                            Text(speaker.name)
                            Spacer()
                            Text("\(speaker.recordingCount) recording\(speaker.recordingCount == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button {
                                SpeakerLibrary.deleteSpeaker(id: speaker.id)
                                knownSpeakers = SpeakerLibrary.speakers
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Forget this voice and its samples")
                        }
                    }
                }
            }

            Section("Speech Recognition Models") {
                ForEach(ModelCatalog.all) { model in
                    ModelRowView(model: model)
                }
                Text("Select a downloaded model to use it for transcription. Smaller models are faster but less accurate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Custom Model") {
                HStack {
                    TextField("GGML model file", text: $modelPath,
                              prompt: Text("Path to a custom ggml model"))
                        .textFieldStyle(.roundedBorder)
                    Button("Browse...") { browseModel() }
                }
                Text("Used only when no model is selected above. Leave empty otherwise.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Local API Server (OpenAI-compatible)") {
                Toggle("Run transcription API server", isOn: $apiServerEnabled)
                    .onChange(of: apiServerEnabled) { _, on in
                        if on { apiServer.start() } else { apiServer.stop() }
                    }

                HStack {
                    Text("Port")
                    Spacer()
                    TextField("8080", value: $apiServerPort, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                        .disabled(apiServer.isRunning)
                }

                SecureField("API Key (optional)", text: $apiServerToken,
                            prompt: Text("Leave empty to allow any client"))
                    .textFieldStyle(.roundedBorder)

                Toggle("Allow access from other devices on your network", isOn: $apiServerAllowLAN)
                    .disabled(apiServer.isRunning)

                Toggle("Verbose request logging (for troubleshooting)", isOn: $apiServerVerboseLog)

                if apiServer.isRunning, let base = apiServer.baseURL {
                    HStack(spacing: 8) {
                        Label("Running", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                        Text("\(base)/v1")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\(base)/v1", forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy base URL")
                        Spacer()
                    }
                } else if let err = apiServer.lastError {
                    Label(err, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                        .lineLimit(3)
                }

                Text("Point any OpenAI-compatible client at the address above (base_url). Endpoints: POST /v1/audio/transcriptions and /v1/audio/translations (multipart with a `file`; response_format supports json, verbose_json, text, srt, vtt). Requests use your currently selected model. Changing the port or network setting takes effect after toggling the server off and on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Backup & Restore") {
                HStack(spacing: 10) {
                    Button("Export Backup…") { exportBackup() }
                    Button("Restore from Backup…") { pickRestoreFile() }
                    Spacer()
                }

                switch backupStatus {
                case .success(let msg):
                    Label(msg, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                case .failure(let msg):
                    Label(msg, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                case .none:
                    EmptyView()
                }

                Text("Saves your settings (model choice, translation API config, font size, recent apps) to one file. On a new Mac, copy your Recordings and Transcriptions folders into ~/Library/Application Support/WhisperASR/ — transcripts load from there and audio links repair automatically — then restore your settings here. The file includes your translation API key, so keep it private.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
        .onAppear { ModelManager.shared.refresh() }
        .confirmationDialog(
            "Restore from backup?",
            isPresented: $showRestoreConfirm,
            titleVisibility: .visible
        ) {
            Button("Restore") { performRestore() }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: {
            Text("This overwrites your current settings (model choice, translation API config, font size, recent apps) with the values from the backup. Your transcriptions are not affected.")
        }
        .sheet(item: $editingPrompt) { prompt in
            MinutesPromptEditorSheet(prompt: prompt) { saved in
                minutesStore.upsert(saved)
            }
        }
        .confirmationDialog(
            "Delete \"\(promptPendingDelete?.name ?? "")\"?",
            isPresented: Binding(
                get: { promptPendingDelete != nil },
                set: { if !$0 { promptPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let prompt = promptPendingDelete {
                    minutesStore.delete(prompt)
                }
                promptPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { promptPendingDelete = nil }
        } message: {
            Text("The prompt text will be removed. This can't be undone.")
        }
        .onAppear {
            knownSpeakers = SpeakerLibrary.speakers
        }
    }

    private func verifyConnection() {
        verifyInFlight = true
        verifyResult = nil
        let lang = targetLanguage.isEmpty ? "en" : targetLanguage
        Task {
            do {
                let translations = try await TranslationService.translateSegmentsWithOpenAI(
                    segmentTexts: ["Hello, world."],
                    targetLanguage: lang
                )
                await MainActor.run {
                    verifyInFlight = false
                    let sample = translations.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if sample.isEmpty {
                        verifyResult = .failure("Empty response")
                    } else {
                        verifyResult = .success("OK — \(sample)")
                    }
                }
            } catch {
                await MainActor.run {
                    verifyInFlight = false
                    verifyResult = .failure(error.localizedDescription)
                }
            }
        }
    }

    private func browseModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                modelPath = url.path
            }
        }
    }

    // MARK: - Backup & Restore

    private static func backupDateString() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date())
    }

    private func exportBackup() {
        let backup = BackupService.makeBackup()
        guard let data = try? BackupService.encode(backup) else {
            backupStatus = .failure("Couldn't create backup data.")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "WhisperASR Backup \(Self.backupDateString()).json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                backupStatus = .success("Settings exported.")
            } catch {
                backupStatus = .failure("Export failed: \(error.localizedDescription)")
            }
        }
    }

    private func pickRestoreFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                pendingRestore = try BackupService.decode(data)
                showRestoreConfirm = true
            } catch {
                backupStatus = .failure("Couldn't read backup: \(error.localizedDescription)")
            }
        }
    }

    private func performRestore() {
        guard let backup = pendingRestore else { return }
        BackupService.restore(backup)
        backupStatus = .success("Settings restored.")
        pendingRestore = nil
    }
}

// MARK: - Minutes Prompt Editor

private struct MinutesPromptEditorSheet: View {
    @State var prompt: MinutesPrompt
    let onSave: (MinutesPrompt) -> Void
    @Environment(\.dismiss) private var dismiss

    private var canSave: Bool {
        !prompt.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !prompt.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Meeting Minutes Prompt")
                .font(.headline)

            TextField("Name (e.g. Weekly Standup, Client Call)", text: $prompt.name)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $prompt.prompt)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(nsColor: .separatorColor))
                )
                .frame(minHeight: 220)

            Text("Describe the structure and focus of the minutes. The transcript is appended automatically, and the result is always formatted as HTML.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    onSave(prompt)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 480, height: 420)
    }
}

// MARK: - Model Row

private struct ModelRowView: View {
    let model: WhisperModelInfo
    @State private var manager = ModelManager.shared
    @State private var confirmDelete = false

    private var downloader: ModelDownloader { manager.downloader(for: model) }
    private var isDownloaded: Bool { manager.isDownloaded(model) }
    private var isSelected: Bool { manager.selectedFileName == model.fileName }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                manager.selectedFileName = model.fileName
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!isDownloaded)
            .help(isDownloaded ? "Use this model for transcription" : "Download the model first")

            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                Text("\(model.detail) · \(model.approxSizeText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isDownloaded {
                Button {
                    confirmDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete downloaded model")
            } else if downloader.state == .downloading {
                ProgressView(value: downloader.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 70)
                Text("\(Int(downloader.progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button {
                    downloader.cancelDownload()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel download")
            } else {
                if case .failed = downloader.state {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("Download failed — click Download to retry")
                }
                Button(downloader.hasResumeData ? "Resume" : "Download") {
                    downloader.startDownload()
                }
            }
        }
        .confirmationDialog(
            "Delete \(model.displayName)?",
            isPresented: $confirmDelete
        ) {
            Button("Delete", role: .destructive) {
                manager.delete(model)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The model file (\(model.approxSizeText)) will be removed from disk. You can download it again later.")
        }
    }
}
