import SwiftUI
import AppKit
import ScreenCaptureKit

@main
struct WhisperASRApp: App {
    @State private var appState = AppState()
    @State private var audioPlayer = AudioPlayerManager()
    @State private var audioRecorder = AudioRecorder()
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("WhisperASR", id: "main") {
            ContentView()
                .environment(appState)
                .environment(audioPlayer)
                .environment(audioRecorder)
                .frame(minWidth: 800, minHeight: 500)
                .onAppear {
                    appDelegate.appState = appState
                    appDelegate.audioRecorder = audioRecorder
                    appDelegate.openWindow = openWindow
                    appDelegate.processPendingURL()
                    // Recover live transcription from a previous crash/hang
                    if appState.hasLiveRecoveryData {
                        appState.importRecoveredTranscription()
                    }
                }
                .onOpenURL { url in
                    appDelegate.handleURL(url)
                }
        }
        .defaultSize(width: 1000, height: 650)

        Window("Record Audio", id: "app-picker") {
            AppPickerView()
                .environment(appState)
                .environment(audioPlayer)
                .environment(audioRecorder)
        }
        .defaultSize(width: 420, height: 400)
        .windowResizability(.contentSize)

        Window("Recording", id: "recording") {
            RecordingView()
                .environment(appState)
                .environment(audioPlayer)
                .environment(audioRecorder)
        }
        .defaultSize(width: 420, height: 250)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Window("Meeting Minutes", id: "minutes") {
            MinutesWindowView()
                .environment(appState)
        }
        .defaultSize(width: 720, height: 820)

        Settings {
            SettingsView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?
    var audioRecorder: AudioRecorder?
    var openWindow: OpenWindowAction?
    var launchedViaURL = false
    private var pendingURL: URL?

    func applicationWillFinishLaunching(_ notification: Notification) {
        let icon = AppIconGenerator.generate()
        NSApplication.shared.applicationIconImage = icon
        let imageView = NSImageView(image: icon)
        NSApplication.shared.dockTile.contentView = imageView
        NSApplication.shared.dockTile.display()
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, url.scheme == "whisperasr" else { return }
        launchedViaURL = true
        // If openWindow is ready, handle immediately; otherwise queue it
        if openWindow != nil {
            handleURL(url)
        } else {
            pendingURL = url
        }
    }

    func handleURL(_ url: URL) {
        guard url.scheme == "whisperasr", url.host == "record",
              let openWindow, let audioRecorder else { return }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        func queryValue(_ key: String) -> String? {
            queryItems.first(where: { $0.name == key })?.value
        }
        func queryBool(_ key: String) -> Bool? {
            guard let val = queryValue(key) else { return nil }
            return val == "true" || val == "1" || val == "yes"
        }

        // Parse optional recording name
        if let name = queryValue("name"), !name.isEmpty {
            audioRecorder.customRecordingName = name
        }

        // Apply optional toggle overrides
        if let mic = queryBool("mic") {
            audioRecorder.includeMicrophone = mic
        }
        if let live = queryBool("live") {
            appState?.enableLiveTranscription = live
        }
        if let translate = queryBool("translate") {
            appState?.enableLiveTranslation = translate
            // Translation requires live transcription
            if translate { appState?.enableLiveTranscription = true }
        }
        if let pin = queryBool("pin") {
            audioRecorder.pinWindow = pin
        }

        // If already recording, just show the recording window
        if audioRecorder.state == .recording {
            openWindow(id: "recording")
            bringWindowToFront(title: "Recording")
            return
        }

        // If app parameter is provided, auto-start recording directly
        if let appName = queryValue("app"), !appName.isEmpty {
            autoStartRecording(appName: appName)
            return
        }

        // Otherwise show the app picker
        openWindow(id: "app-picker")
        bringWindowToFront(title: "Record Audio")
    }

    /// Find the named app and start recording automatically, skipping the picker.
    private func autoStartRecording(appName: String) {
        guard let audioRecorder, let openWindow else { return }

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                let myBundleID = Bundle.main.bundleIdentifier ?? "com.whisperasr"
                let appsWithWindows = Set(content.windows.map { $0.owningApplication?.bundleIdentifier })
                let apps = content.applications.filter {
                    $0.bundleIdentifier != myBundleID
                        && !$0.applicationName.isEmpty
                        && appsWithWindows.contains($0.bundleIdentifier)
                        && NSRunningApplication(processIdentifier: $0.processID)?.activationPolicy == .regular
                }

                // Match by case-insensitive substring
                let lowerName = appName.lowercased()
                guard let matchedApp = apps.first(where: { $0.applicationName.lowercased().contains(lowerName) }) else {
                    await MainActor.run {
                        audioRecorder.error = "App \"\(appName)\" not found"
                        audioRecorder.availableApps = apps
                        audioRecorder.state = .ready
                        openWindow(id: "app-picker")
                        self.bringWindowToFront(title: "Record Audio")
                    }
                    return
                }

                await MainActor.run {
                    audioRecorder.state = .ready
                    audioRecorder.startRecording(app: matchedApp)
                    openWindow(id: "recording")
                    self.bringWindowToFront(title: "Recording")
                }
            } catch {
                await MainActor.run {
                    audioRecorder.error = "Failed to list apps: \(error.localizedDescription)"
                    openWindow(id: "app-picker")
                    self.bringWindowToFront(title: "Record Audio")
                }
            }
        }
    }

    private func bringWindowToFront(title: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            // Hide the main window if this was a cold launch via URL
            if self.launchedViaURL {
                for window in NSApplication.shared.windows where window.title == "WhisperASR" {
                    window.orderOut(nil)
                }
            }
            // Bring target window to front
            for window in NSApplication.shared.windows where window.title == title {
                window.makeKeyAndOrderFront(nil)
                break
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    func processPendingURL() {
        if let url = pendingURL {
            pendingURL = nil
            handleURL(url)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.shutdown()
    }
}
