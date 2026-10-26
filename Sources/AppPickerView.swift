import SwiftUI
import ScreenCaptureKit

struct AppPickerView: View {
    @Environment(AppState.self) var appState
    @Environment(AudioRecorder.self) var recorder
    @Environment(\.dismiss) var dismiss
    @Environment(\.openWindow) var openWindow
    @State private var searchText = ""
    @State private var modelManager = ModelManager.shared
    @AppStorage("liveTranslationPref") private var liveTranslationPref = false

    var body: some View {
        @Bindable var appState = appState
        @Bindable var recorder = recorder
        return VStack(spacing: 0) {
            switch recorder.state {
            case .idle, .loading:
                loadingContent
            case .ready:
                pickerContent
            case .starting:
                ProgressView("Starting recording…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .permissionDenied:
                permissionDeniedContent
            default:
                Color.clear.onAppear { dismiss() }
            }
        }
        .frame(
            minWidth: 360, idealWidth: 420, maxWidth: .infinity,
            minHeight: 400, idealHeight: 400, maxHeight: .infinity
        )
        .background(WindowPositioner())
        .onChange(of: appState.enableLiveTranscription) { _, newValue in
            if !newValue { appState.enableLiveTranslation = false }
        }
        .onChange(of: recorder.state) { _, state in
            if state == .recording {
                openWindow(id: "recording")
                dismiss()
            }
        }
        .onAppear {
            if recorder.state == .idle {
                recorder.loadAvailableApps()
            }
            appState.enableLiveTranslation = liveTranslationPref
            modelManager.refresh()
        }
    }

    // MARK: - Loading

    private var loadingContent: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading applications...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Picker

    private var pickerContent: some View {
        @Bindable var appState = appState
        @Bindable var recorder = recorder
        return VStack(spacing: 0) {
            if let error = recorder.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
            }

            Picker("Audio source", selection: $recorder.recordingSource) {
                Text("All System Audio").tag(RecordingSource.system)
                Text("Specific App").tag(RecordingSource.application)
            }
            .pickerStyle(.segmented)
            .padding(12)

            if recorder.recordingSource == .application {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search apps...", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 4)

                List(filteredApps, id: \.bundleIdentifier, selection: Binding(
                    get: { recorder.selectedApp?.bundleIdentifier },
                    set: { id in
                        recorder.selectedApp = recorder.availableApps.first { $0.bundleIdentifier == id }
                    }
                )) { app in
                    HStack(spacing: 10) {
                        appIcon(for: app)
                            .frame(width: 24, height: 24)
                        Text(app.applicationName)
                            .lineLimit(1)
                    }
                    .tag(app.bundleIdentifier)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("Record audio from all apps")
                        .font(.headline)
                    Text("Includes sounds from other apps and notifications. WhisperASR’s own playback is excluded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            HStack(spacing: 12) {
                Toggle(isOn: $recorder.includeMicrophone) {
                    Label("Microphone", systemImage: "mic")
                }
                Toggle(isOn: $appState.enableLiveTranscription) {
                    Label("Live", systemImage: "text.word.spacing")
                }
                Toggle(isOn: Binding(
                    get: { appState.enableLiveTranslation },
                    set: { appState.enableLiveTranslation = $0; liveTranslationPref = $0 }
                )) {
                    Image(systemName: "character.bubble")
                }
                .disabled(!appState.enableLiveTranscription)
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if recorder.includeMicrophone {
                Toggle("Reduce speaker echo", isOn: $recorder.reduceSpeakerEcho)
                    .toggleStyle(.checkbox)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .help("Uses macOS voice processing to reduce speaker sound picked up by the microphone. May slightly lower other audio; turn off for unprocessed microphone audio.")
            }

            if appState.enableLiveTranscription {
                HStack(spacing: 6) {
                    Text("Live model:")
                        .foregroundStyle(.secondary)
                    Picker("Live transcription model", selection: Binding(
                        get: { modelManager.liveFileName },
                        set: { modelManager.liveFileName = $0 }
                    )) {
                        Text("Same as transcription model").tag("")
                        ForEach(modelManager.downloadedModels) { model in
                            Text(model.displayName).tag(model.fileName)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                }
                .font(.caption)
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .help("A smaller, faster model keeps up with live audio; the final transcription of the recording still uses the main model")
            }

            HStack {
                Button("Cancel") {
                    recorder.state = .idle
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Start Recording") {
                    recorder.startRecording()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!recorder.canStartRecording)
            }
            .padding(12)
        }
    }

    // MARK: - Permission Denied

    private var permissionDeniedContent: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "lock.shield")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            Text("Screen Recording Permission Required")
                .font(.headline)

            Text("WhisperASR needs Screen Recording permission to capture audio from other applications.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)

            HStack(spacing: 12) {
                Button("Open System Settings") {
                    recorder.openSystemPreferences()
                }
                .buttonStyle(.borderedProminent)

                Button("Try Again") {
                    recorder.loadAvailableApps()
                }
            }

            Spacer()

            Button("Cancel") {
                recorder.state = .idle
                dismiss()
            }
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private var filteredApps: [SCRunningApplication] {
        guard !searchText.isEmpty else { return sortedApps }
        return sortedApps.filter {
            $0.applicationName.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var sortedApps: [SCRunningApplication] {
        let recent = recorder.recentAppBundleIDs
        return recorder.availableApps.sorted { a, b in
            let aIdx = recent.firstIndex(of: a.bundleIdentifier)
            let bIdx = recent.firstIndex(of: b.bundleIdentifier)
            switch (aIdx, bIdx) {
            case let (.some(ai), .some(bi)): return ai < bi
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a.applicationName < b.applicationName
            }
        }
    }

    private func appIcon(for app: SCRunningApplication) -> some View {
        Group {
            if let nsApp = NSRunningApplication(processIdentifier: app.processID),
               let icon = nsApp.icon {
                Image(nsImage: icon)
                    .resizable()
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(contentMode: .fit)
    }
}

// MARK: - Window Positioner

/// Centers this window on the main WhisperASR window each time it becomes key,
/// synchronously (before any drawing) so there is no visible jump.
private struct WindowPositioner: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { PositionView(coordinator: context.coordinator) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    class PositionView: NSView {
        let coordinator: Coordinator
        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window, coordinator.window == nil {
                coordinator.observe(window)
            }
        }
    }

    class Coordinator: NSObject {
        weak var window: NSWindow?

        func observe(_ window: NSWindow) {
            self.window = window
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidBecomeKey(_:)),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
        }

        @objc func windowDidBecomeKey(_ notification: Notification) {
            guard let window = notification.object as? NSWindow,
                  let mainWindow = NSApplication.shared.windows.first(where: {
                      $0 !== window && $0.isVisible && $0.title != "Recording"
                  }) else { return }
            let mf = mainWindow.frame
            let wf = window.frame
            window.setFrameOrigin(NSPoint(x: mf.midX - wf.width / 2, y: mf.midY - wf.height / 2))
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
