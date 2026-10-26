import SwiftUI
import ScreenCaptureKit

struct RecordingView: View {
    @Environment(AppState.self) var appState
    @Environment(AudioRecorder.self) var recorder
    @Environment(\.dismiss) var dismiss
    @State private var shouldAutoScroll = true
    @State private var isAlwaysOnTop = false
    @State private var translationOnly = false
    @AppStorage("transcriptFontSize") private var transcriptFontSizeRaw = TranscriptFontSize.normal.rawValue
    private var fontSize: TranscriptFontSize { TranscriptFontSize(rawValue: transcriptFontSizeRaw) ?? .normal }

    var body: some View {
        VStack(spacing: 0) {
            switch recorder.state {
            case .recording:
                recordingContent
            case .saving:
                savingContent
            case .starting:
                ProgressView("Starting recording…")
            case .ready:
                if let error = recorder.error {
                    Text(error).foregroundStyle(.red).padding()
                }
            default:
                Color.clear
            }
        }
        .frame(
            minWidth: 360, idealWidth: 420, maxWidth: .infinity,
            minHeight: appState.enableLiveTranscription ? 200 : 76,
            idealHeight: appState.enableLiveTranscription ? 300 : 76,
            maxHeight: appState.enableLiveTranscription || recorder.error != nil ? .infinity : 76
        )
        .background(WindowConfigurator())
    }

    // MARK: - Recording

    private var recordingContent: some View {
        @Bindable var recorder = recorder
        return VStack(spacing: 0) {
            HStack {
                Text(recorder.recordingSourceName)
                    .lineLimit(1)
                Spacer()
                Text(recorder.microphoneStatus)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            if let error = recorder.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
            }
            // Live transcription area (only shown if enabled)
            if appState.enableLiveTranscription {
                liveTranscriptView
                Divider()
            }

            // Bottom bar: indicator + action buttons + window controls
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                        .shadow(color: .red.opacity(0.6), radius: 4)
                        .modifier(PulsingModifier())
                    Text(formatDuration(recorder.recordingDuration))
                        .font(.system(size: 13, weight: .light, design: .monospaced))
                }

                Spacer()

                Button("Cancel") {
                    appState.stopLiveTranscription()
                    recorder.cancelRecording()
                    dismiss()
                }

                Button("Finish Recording") {
                    stopAndDismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Divider()
                    .frame(height: 16)

                if appState.enableLiveTranslation {
                    Button {
                        appState.setLiveTranslationPaused(!appState.liveTranslationPaused)
                    } label: {
                        Image(systemName: appState.liveTranslationPaused ? "character.bubble" : "character.bubble.fill")
                            .foregroundStyle(appState.liveTranslationPaused ? Color.secondary : Color.blue)
                    }
                    .buttonStyle(.plain)
                    .help(appState.liveTranslationPaused ? "Resume translation" : "Pause translation (e.g. speaker switched to your language)")

                    Button {
                        translationOnly.toggle()
                    } label: {
                        Image(systemName: translationOnly ? "eye.fill" : "eye")
                            .foregroundStyle(translationOnly ? .blue : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(translationOnly ? "Show original and translation" : "Show translation only")
                }

                Button {
                    isAlwaysOnTop.toggle()
                    setWindowAlwaysOnTop(isAlwaysOnTop)
                } label: {
                    Image(systemName: isAlwaysOnTop ? "pin.fill" : "pin")
                        .foregroundStyle(isAlwaysOnTop ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .help(isAlwaysOnTop ? "Unpin window" : "Keep on top of all windows")

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if appState.enableLiveTranscription, !appState.isLiveTranscribing {
                appState.startLiveTranscription(recorder: recorder)
            }
            if recorder.pinWindow {
                recorder.pinWindow = false
                isAlwaysOnTop = true
                setWindowAlwaysOnTop(true)
            }
        }
    }

    // MARK: - Live Transcript

    private var liveTranscriptView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let message = appState.liveError {
                errorBanner(message: message, tint: .red)
            }
            if let message = appState.liveTranslationError {
                errorBanner(message: message, tint: .orange)
            }
            if appState.isLiveTranscribing && appState.liveSegments.isEmpty {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for audio...")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal)
                .frame(maxHeight: .infinity)
            }

            if !appState.liveSegments.isEmpty {
                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(appState.liveSegments.enumerated()), id: \.offset) { index, segment in
                            LiveSegmentRow(
                                segment: segment,
                                translation: index < appState.liveTranslatedSegments.count
                                    ? appState.liveTranslatedSegments[index] : "",
                                fontSize: fontSize,
                                translationOnly: translationOnly
                            )
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
                            .listRowBackground(Color.clear)
                        }

                        // Tail padding: keeps the last transcript line clear of the
                        // action bar below the list after auto-scroll (rows can grow
                        // when a translation arrives after the scroll already happened).
                        Color.clear
                            .frame(height: 28)
                            .id("bottomAnchor")
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .environment(\.defaultMinListRowHeight, 1)
                    .background(
                        ScrollPositionObserver(isAtBottom: $shouldAutoScroll)
                            .frame(width: 0, height: 0)
                            .allowsHitTesting(false)
                    )
                    .onChange(of: appState.liveSegments.count) { _, _ in
                        deferredScrollToBottom(proxy: proxy)
                    }
                    .onChange(of: appState.liveTranslatedSegments) { _, _ in
                        deferredScrollToBottom(proxy: proxy)
                    }
                    .overlay { WindowDragOverlay() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Saving

    private var savingContent: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Saving recording...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func errorBanner(message: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(tint)
            Text(message)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(tint.opacity(0.12))
    }

    /// Defer the actual scroll until the List finishes layout, and re-check
    /// shouldAutoScroll inside the dispatch so a concurrent user scroll-up
    /// (which updates the flag synchronously via the observer) takes effect
    /// before we decide whether to snap back to the bottom.
    private func deferredScrollToBottom(proxy: ScrollViewProxy) {
        guard !appState.liveSegments.isEmpty else { return }
        DispatchQueue.main.async {
            guard shouldAutoScroll else { return }
            proxy.scrollTo("bottomAnchor", anchor: .bottom)
        }
    }

    private func stopAndDismiss() {
        Task {
            await appState.finishRecording(recorder: recorder)
            dismiss()
        }
    }

    private func setWindowAlwaysOnTop(_ alwaysOnTop: Bool) {
        NSApplication.shared.windows
            .first { $0.title == "Recording" }?
            .level = alwaysOnTop ? .floating : .normal
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

}

// MARK: - Live Segment Row

/// Extracted row view with Equatable conformance so SwiftUI can skip
/// re-rendering rows whose segment + translation haven't changed.
private struct LiveSegmentRow: View, Equatable {
    let segment: TranscriptionSegment
    let translation: String
    let fontSize: TranscriptFontSize
    let translationOnly: Bool

    private static let translationColor = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.systemTeal.withAlphaComponent(0.85)
            : NSColor.systemBlue.withAlphaComponent(0.75)
    }))

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !translationOnly {
                Text(segment.text.trimmingCharacters(in: .whitespaces))
                    .font(fontSize.bodyFont)
                    .foregroundStyle(.primary.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !translation.isEmpty {
                Text(translation)
                    .font(translationOnly ? fontSize.bodyFont : fontSize.translationFont)
                    .foregroundStyle(Self.translationColor)
                    .italic(translationOnly ? false : true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Scroll Position Observer

/// Observes the enclosing NSScrollView's scroll position via native bounds-change
/// notifications. Uses a 150px threshold to tolerate content growth (e.g. translations
/// appended) without prematurely disabling auto-scroll.
private struct ScrollPositionObserver: NSViewRepresentable {
    @Binding var isAtBottom: Bool

    class PassthroughView: NSView {
        var onMoveToWindow: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                onMoveToWindow?()
            }
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        view.onMoveToWindow = {
            context.coordinator.attemptSetup(view: view)
        }
        context.coordinator.attemptSetup(view: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attemptSetup(view: nsView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isAtBottom: $isAtBottom)
    }

    class Coordinator: NSObject {
        @Binding var isAtBottom: Bool
        private var isSetUp = false
        private var retryCount = 0

        init(isAtBottom: Binding<Bool>) {
            _isAtBottom = isAtBottom
        }

        /// The underlying NSScrollView (backing SwiftUI's List) may not be in the
        /// view hierarchy when makeNSView / viewDidMoveToWindow fire. Retry with a
        /// short delay so the observer attaches reliably; otherwise isAtBottom
        /// stays at its initial value (true) forever and auto-scroll never stops.
        func attemptSetup(view: NSView) {
            guard !isSetUp else { return }
            if let scrollView = view.enclosingScrollView ?? Self.findScrollView(from: view) {
                isSetUp = true
                scrollView.contentView.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(scrollViewDidScroll(_:)),
                    name: NSView.boundsDidChangeNotification,
                    object: scrollView.contentView
                )
                return
            }
            guard retryCount < 30 else { return }
            retryCount += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak view] in
                guard let self, let view else { return }
                self.attemptSetup(view: view)
            }
        }

        /// Walk up the view hierarchy and search sibling subtrees for an NSScrollView
        /// whose document view is an NSTableView (i.e., the List's backing scroll view).
        private static func findScrollView(from view: NSView) -> NSScrollView? {
            var current: NSView? = view.superview
            while let parent = current {
                if let found = findTableScrollView(in: parent) { return found }
                current = parent.superview
            }
            return nil
        }

        private static func findTableScrollView(in view: NSView) -> NSScrollView? {
            if let sv = view as? NSScrollView, sv.documentView is NSTableView { return sv }
            for subview in view.subviews {
                if let found = findTableScrollView(in: subview) { return found }
            }
            return nil
        }

        @objc func scrollViewDidScroll(_ notification: Notification) {
            guard let clipView = notification.object as? NSClipView,
                  let scrollView = clipView.enclosingScrollView,
                  let documentView = scrollView.documentView else { return }
            let contentHeight = documentView.frame.height
            let visibleHeight = clipView.bounds.height
            let scrollOffset = clipView.bounds.origin.y
            let distanceFromBottom: CGFloat
            if documentView.isFlipped {
                distanceFromBottom = contentHeight - scrollOffset - visibleHeight
            } else {
                distanceFromBottom = scrollOffset
            }
            // Update synchronously on main so a subsequent onChange(liveSegments)
            // observes the new value. A main.async update can lose the race and
            // cause auto-scroll to snap back to bottom even after the user scrolled up.
            let atBottom = distanceFromBottom <= 150
            if Thread.isMainThread {
                if isAtBottom != atBottom { isAtBottom = atBottom }
            } else {
                DispatchQueue.main.async {
                    if self.isAtBottom != atBottom { self.isAtBottom = atBottom }
                }
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

// MARK: - Window Configurator

/// Hides traffic lights and enables drag-to-move on the Recording window.
private struct WindowConfigurator: NSViewRepresentable {
    class ConfigView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isMovableByWindowBackground = true
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
        }
    }

    func makeNSView(context: Context) -> NSView { ConfigView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Window Drag Overlay

/// Transparent overlay that lets single-finger click+drag move the window
/// while forwarding two-finger trackpad scroll events to the List beneath.
private struct WindowDragOverlay: NSViewRepresentable {
    class DragView: NSView {
        weak var targetScrollView: NSScrollView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                self?.targetScrollView = self?.findScrollView()
            }
        }

        /// Pass hit-tests through to views beneath when the point is over a
        /// visible scrollbar. Without this, clicks on the scrollbar start a
        /// window drag (via mouseDown below) instead of letting the scroller
        /// handle them.
        override func hitTest(_ point: NSPoint) -> NSView? {
            if targetScrollView == nil { targetScrollView = findScrollView() }
            if let scrollView = targetScrollView,
               let scroller = scrollView.verticalScroller,
               !scroller.isHidden,
               scroller.alphaValue > 0.01,
               let superview = superview {
                let pointInScroller = scroller.convert(point, from: superview)
                if scroller.bounds.contains(pointInScroller) {
                    return nil
                }
            }
            return super.hitTest(point)
        }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        override func scrollWheel(with event: NSEvent) {
            if targetScrollView == nil { targetScrollView = findScrollView() }
            targetScrollView?.scrollWheel(with: event)
        }

        private func findScrollView() -> NSScrollView? {
            var current: NSView? = superview
            while let parent = current {
                if let sv = Self.findTableScrollView(in: parent) { return sv }
                current = parent.superview
            }
            return nil
        }

        private static func findTableScrollView(in view: NSView) -> NSScrollView? {
            if let sv = view as? NSScrollView, sv.documentView is NSTableView { return sv }
            for sub in view.subviews {
                if let found = findTableScrollView(in: sub) { return found }
            }
            return nil
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Pulsing Animation

/// Pulses opacity 1.0 → 0.4 on a 1.6s cycle. Driven by a single repeating
/// Core Animation, not a TimelineView — a 10Hz timeline re-evaluated SwiftUI
/// continuously for the whole recording session, exactly when the CPU is
/// already busy with capture + live whisper.
private struct PulsingModifier: ViewModifier {
    @State private var dimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(dimmed ? 0.4 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: dimmed)
            .onAppear { dimmed = true }
    }
}
