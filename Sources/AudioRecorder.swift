import Foundation
import ScreenCaptureKit
import AVFoundation
import Observation
import os
import CoreGraphics
import Darwin

enum RecordingState: Equatable {
    case idle
    case loading
    case ready
    case starting
    case recording
    case saving
    case permissionDenied
}

enum RecordingSource: String, CaseIterable {
    case system
    case application
}

@Observable
class AudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    var state: RecordingState = .idle
    var availableApps: [SCRunningApplication] = []
    var selectedApp: SCRunningApplication? {
        didSet {
            if let selectedApp {
                UserDefaults.standard.set(selectedApp.bundleIdentifier, forKey: "recordingAppBundleID")
            }
        }
    }
    var recordingSource = RecordingSource(rawValue: UserDefaults.standard.string(forKey: "recordingSource") ?? "") ?? .system {
        didSet { UserDefaults.standard.set(recordingSource.rawValue, forKey: "recordingSource") }
    }
    var recordingDuration: TimeInterval = 0
    var error: String?
    var meetingEnded = false
    var includeMicrophone = UserDefaults.standard.object(forKey: "recordingIncludeMicrophone") as? Bool ?? true {
        didSet { UserDefaults.standard.set(includeMicrophone, forKey: "recordingIncludeMicrophone") }
    }
    var reduceSpeakerEcho = UserDefaults.standard.object(forKey: "recordingReduceSpeakerEcho") as? Bool ?? true {
        didSet { UserDefaults.standard.set(reduceSpeakerEcho, forKey: "recordingReduceSpeakerEcho") }
    }
    private(set) var recordingSourceName = ""
    private(set) var microphoneStatus = ""
    var onMeetingEnded: (() -> Void)?
    var customRecordingName: String?
    var pinWindow = false

    private var stream: SCStream?
    @ObservationIgnored private var assetWriter: AVAssetWriter?
    @ObservationIgnored private var assetWriterInput: AVAssetWriterInput?
    private var timer: Timer?
    private var recordingStartTime: Date?
    private var outputURL: URL?
    private var _hasReceivedSamples = OSAllocatedUnfairLock(initialState: false)
    private var meetingMonitorTimer: Timer?
    private var recordingPID: pid_t?
    private var meetingStarted = false

    // Stream watchdog: detect stalled audio delivery and restart
    private var lastAudioBufferTime = OSAllocatedUnfairLock(initialState: Date())
    private var audioWatchdogTimer: Timer?
    private var recordingApp: SCRunningApplication?
    private var isRestartingStream = false
    /// How long without audio before we consider the stream stalled (seconds).
    private static let audioStallThreshold: TimeInterval = 15

    // The writer, mixer, resampler and timeline are confined to audioQueue.
    private let audioQueue = DispatchQueue(label: "com.whisperasr.audio-capture")
    private let activeStreamID = OSAllocatedUnfairLock(initialState: Optional<ObjectIdentifier>.none)
    private var audioEngine: AVAudioEngine?
    private var engineObserver: NSObjectProtocol?
    @ObservationIgnored private var mixer: RecordingAudioMixer?
    @ObservationIgnored private var mixTimer: DispatchSourceTimer?
    @ObservationIgnored private var captureSessionID: UUID?
    @ObservationIgnored private var timelineOrigin: TimeInterval = 0
    @ObservationIgnored private var writeFailureReported = false
    // Allow for microphone tap buffering and delivery jitter before emitting a block.
    private static let mixingDelay: TimeInterval = 0.3

    // Live transcription: accumulated 16kHz mono PCM samples.
    // Buffer + trimOffset are in a single lock so reads/writes are always atomic.
    private struct PCMState {
        var buffer: [Float] = []
        var trimOffset: Int = 0
    }
    private var pcmState = OSAllocatedUnfairLock(initialState: PCMState())

    // 48kHz → 16kHz resampler for live transcription (AVAudioConverter applies
    // a proper anti-alias low-pass filter; naive decimation aliased above 8kHz).
    private static let pcmSourceFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
    private static let pcmTargetFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    @ObservationIgnored
    private lazy var pcmResampler: AVAudioConverter? = {
        AVAudioConverter(from: AudioRecorder.pcmSourceFormat, to: AudioRecorder.pcmTargetFormat)
    }()
    /// Total number of 16kHz samples accumulated since recording started (absolute count).
    var accumulatedSampleCount: Int {
        pcmState.withLock { $0.trimOffset + $0.buffer.count }
    }

    private static let zoomBundleIDs: Set<String> = ["us.zoom.xos", "us.zoom.videomeeting"]

    // MARK: - Live Transcription PCM Access

    /// Returns a copy of all accumulated 16kHz PCM samples for live transcription.
    func getAccumulatedSamples() -> [Float] {
        pcmState.withLock { Array($0.buffer) }
    }

    /// Returns only the samples from absolute `startIndex` onward — avoids copying the entire
    /// buffer during long recordings (which can be hundreds of MB after 30+ minutes).
    func getSamples(from startIndex: Int) -> [Float] {
        pcmState.withLock { state in
            let bufIndex = startIndex - state.trimOffset
            guard bufIndex >= 0, bufIndex < state.buffer.count else { return [] }
            return Array(state.buffer[bufIndex...])
        }
    }

    /// Returns the samples in the absolute range `[startIndex, endIndex)` — used to copy only the
    /// audio a chunk needs when its end is held back from the live tail.
    func getSamples(from startIndex: Int, upTo endIndex: Int) -> [Float] {
        pcmState.withLock { state in
            let bufStart = startIndex - state.trimOffset
            let bufEnd = min(endIndex - state.trimOffset, state.buffer.count)
            guard bufStart >= 0, bufEnd > bufStart else { return [] }
            return Array(state.buffer[bufStart..<bufEnd])
        }
    }

    /// Trim committed samples from the front of the PCM buffer to cap memory usage.
    /// `upTo` is an absolute sample index — samples before this index are freed.
    func trimSamples(upTo absoluteIndex: Int) {
        pcmState.withLock { state in
            let bufIndex = absoluteIndex - state.trimOffset
            guard bufIndex > 0 else { return }
            let trimCount = min(bufIndex, state.buffer.count)
            state.buffer.removeFirst(trimCount)
            state.trimOffset += trimCount
        }
    }

    /// Compute the RMS energy of a range of samples without copying the buffer.
    /// Used by the transcription loop to skip whisper inference on silence.
    func rmsEnergy(from startIndex: Int, count: Int) -> Float {
        pcmState.withLock { state in
            let bufStart = startIndex - state.trimOffset
            guard bufStart >= 0 else { return 0 }
            let bufEnd = min(bufStart + count, state.buffer.count)
            guard bufEnd > bufStart else { return 0 }
            var sumSquares: Float = 0
            for i in bufStart..<bufEnd {
                let s = state.buffer[i]
                sumSquares += s * s
            }
            return sqrt(sumSquares / Float(bufEnd - bufStart))
        }
    }

    /// Scan the absolute range `[searchFrom, searchTo)` in fixed `frameSamples`-sized frames and
    /// return the absolute sample index at the START of the rightmost silence run of at least
    /// `minSilenceFrames` frames, provided at least one speech frame precedes it. A frame is
    /// "silent" when its RMS is below `silenceThreshold`.
    ///
    /// Used to place live-transcription chunk cuts at natural pauses: cutting here lets the loop
    /// commit the completed utterance and hold back any trailing in-progress speech. Returns nil
    /// when no qualifying trailing silence exists (e.g. continuous speech). Computed under a single
    /// lock so it stays atomic with concurrent appends/trims.
    func lastSilenceCut(searchFrom: Int, searchTo: Int,
                        frameSamples: Int, silenceThreshold: Float, minSilenceFrames: Int) -> Int? {
        pcmState.withLock { state in
            let bufStart = max(0, searchFrom - state.trimOffset)
            let bufEnd = min(searchTo - state.trimOffset, state.buffer.count)
            guard frameSamples > 0, bufEnd - bufStart >= frameSamples else { return nil }

            // Per-frame silence flags over the search range.
            let frameCount = (bufEnd - bufStart) / frameSamples
            guard frameCount > 0 else { return nil }
            var isSilent = [Bool](repeating: false, count: frameCount)
            for f in 0..<frameCount {
                let s = bufStart + f * frameSamples
                let e = s + frameSamples
                var sumSquares: Float = 0
                for i in s..<e {
                    let v = state.buffer[i]
                    sumSquares += v * v
                }
                isSilent[f] = sqrt(sumSquares / Float(frameSamples)) < silenceThreshold
            }

            // Walk from the right: find the rightmost run of >= minSilenceFrames silent frames
            // whose start has at least one speech frame before it.
            var run = 0
            var f = frameCount - 1
            while f >= 0 {
                if isSilent[f] {
                    run += 1
                    if run >= minSilenceFrames {
                        let runStartFrame = f               // start of this silence run
                        let hasSpeechBefore = (0..<runStartFrame).contains { !isSilent[$0] }
                        guard hasSpeechBefore else { return nil }
                        return state.trimOffset + bufStart + runStartFrame * frameSamples
                    }
                } else {
                    run = 0
                }
                f -= 1
            }
            return nil
        }
    }

    /// Clears the accumulated PCM sample buffer (called when recording ends).
    private func clearPCMBuffer() {
        pcmState.withLock { state in
            state.buffer.removeAll()
            state.trimOffset = 0
        }
    }

    // MARK: - App List

    func loadAvailableApps() {
        state = .loading
        error = nil

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                let myBundleID = Bundle.main.bundleIdentifier ?? "com.whisperasr"
                let appsWithWindows = Set(content.windows.map { $0.owningApplication?.bundleIdentifier })
                let apps = content.applications
                    .filter {
                        $0.bundleIdentifier != myBundleID
                            && !$0.applicationName.isEmpty
                            && appsWithWindows.contains($0.bundleIdentifier)
                            && NSRunningApplication(processIdentifier: $0.processID)?.activationPolicy == .regular
                    }
                    .sorted { ($0.applicationName) < ($1.applicationName) }

                await MainActor.run {
                    self.availableApps = apps
                    let savedID = UserDefaults.standard.string(forKey: "recordingAppBundleID")
                    self.selectedApp = apps.first { $0.bundleIdentifier == savedID }
                    self.state = .ready
                }
            } catch {
                await MainActor.run {
                    if (error as NSError).code == -3801 || "\(error)".contains("denied") {
                        self.state = .permissionDenied
                    } else {
                        self.error = error.localizedDescription
                        self.state = .permissionDenied
                    }
                }
            }
        }
    }

    // MARK: - Start Recording

    private static let recentAppsKey = "recentRecordingApps"

    /// Bundle IDs of recently recorded apps, most recent first.
    var recentAppBundleIDs: [String] {
        UserDefaults.standard.stringArray(forKey: Self.recentAppsKey) ?? []
    }

    private func saveRecentApp(bundleID: String) {
        var recent = recentAppBundleIDs
        recent.removeAll { $0 == bundleID }
        recent.insert(bundleID, at: 0)
        if recent.count > 10 { recent = Array(recent.prefix(10)) }
        UserDefaults.standard.set(recent, forKey: Self.recentAppsKey)
    }

    var canStartRecording: Bool {
        state == .ready && (recordingSource == .system || selectedApp != nil)
    }

    func startRecording() {
        guard canStartRecording else { return }
        startRecording(app: recordingSource == .system ? nil : selectedApp)
    }

    private func makeStream(display: SCDisplay, app: SCRunningApplication?) throws -> SCStream {
        let filter: SCContentFilter
        if let app {
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.channelCount = 1
        config.sampleRate = 48000
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        return stream
    }

    private static func captureError(_ message: String) -> NSError {
        NSError(domain: "WhisperASR.Recording", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static var hostTime: TimeInterval {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }

    func startRecording(app: SCRunningApplication?) {
        guard state == .ready else { return }
        state = .starting
        error = nil
        meetingEnded = false
        let captureMicrophone = includeMicrophone
        let echoReduction = reduceSpeakerEcho
        let sessionID = UUID()
        recordingSourceName = app?.applicationName ?? "All System Audio"
        microphoneStatus = captureMicrophone ? "Microphone" : "Microphone off"

        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else {
                    throw Self.captureError("No display found")
                }
                if captureMicrophone {
                    guard AVCaptureDevice.default(for: .audio) != nil else {
                        throw Self.captureError("No microphone is connected. Connect a microphone and select it in System Settings > Sound > Input, or turn off Microphone to record system audio only.")
                    }
                    let granted = await AVCaptureDevice.requestAccess(for: .audio)
                    guard granted else {
                        throw Self.captureError("Microphone access is denied. Allow WhisperASR in System Settings > Privacy & Security > Microphone, or turn off Microphone.")
                    }
                    try startMicrophoneCapture(sessionID: sessionID, reduceEcho: echoReduction)
                    microphoneStatus = echoReduction ? "Microphone · Echo reduction on" : "Microphone · Echo reduction off"
                }
                let newStream = try makeStream(display: display, app: app)
                let fileURL = makeOutputURL(appName: recordingSourceName)
                let writer = try AVAssetWriter(outputURL: fileURL, fileType: .m4a)
                outputURL = fileURL
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64000,
                ])
                input.expectsMediaDataInRealTime = true
                writer.add(input)
                guard writer.startWriting() else {
                    throw writer.error ?? Self.captureError("Could not create the recording file")
                }
                writer.startSession(atSourceTime: .zero)
                clearPCMBuffer()
                _hasReceivedSamples.withLock { $0 = false }
                audioQueue.sync {
                    self.assetWriter = writer
                    self.assetWriterInput = input
                    self.pcmResampler?.reset()
                    self.mixer = RecordingAudioMixer()
                    self.captureSessionID = sessionID
                    self.timelineOrigin = Self.hostTime
                    self.writeFailureReported = false
                }
                recordingStartTime = Date()
                recordingApp = app
                stream = newStream
                activeStreamID.withLock { $0 = ObjectIdentifier(newStream) }
                try await newStream.startCapture()
                audioQueue.sync {
                    let timer = DispatchSource.makeTimerSource(queue: self.audioQueue)
                    timer.schedule(deadline: .now(), repeating: .milliseconds(20))
                    timer.setEventHandler { [weak self] in
                        self?.renderAudio(until: Self.hostTime - Self.mixingDelay)
                    }
                    self.mixTimer = timer
                    timer.resume()
                }
                customRecordingName = nil
                if let app { saveRecentApp(bundleID: app.bundleIdentifier) }
                state = .recording
                recordingDuration = 0
                timer = Self.commonModeTimer(interval: 1.0) { [weak self] in
                    guard let self, let start = self.recordingStartTime else { return }
                    self.recordingDuration = Date().timeIntervalSince(start)
                }
                if let app { startMeetingMonitor(app: app) }
                startAudioWatchdog()
            } catch {
                activeStreamID.withLock { $0 = nil }
                if let stream { try? await stream.stopCapture() }
                stream = nil
                stopMicrophoneCapture()
                audioQueue.sync {
                    self.endAudioTimeline()
                    self.assetWriter?.cancelWriting()
                    self.assetWriter = nil
                    self.assetWriterInput = nil
                }
                if let url = outputURL { try? FileManager.default.removeItem(at: url) }
                outputURL = nil
                recordingApp = nil
                self.error = "Failed to start recording: \(error.localizedDescription)"
                state = .ready
            }
        }
    }

    // MARK: - Stop / Cancel Recording

    func stopRecording() async -> URL? {
        let endTime = Self.hostTime
        audioQueue.sync { self.mixTimer?.cancel(); self.mixTimer = nil }
        await MainActor.run {
            state = .saving
            timer?.invalidate()
            timer = nil
            stopMeetingMonitor()
            stopAudioWatchdog()
        }
        if let stream { try? await stream.stopCapture() }
        activeStreamID.withLock { $0 = nil }
        self.stream = nil
        stopMicrophoneCapture()
        // Flush the delayed tail before finishing the file. This also drains
        // microphone callbacks already enqueued by the tap.
        let writer: AVAssetWriter? = audioQueue.sync {
            self.renderAudio(until: endTime, flush: true)
            self.endAudioTimeline()
            self.assetWriterInput?.markAsFinished()
            return self.assetWriter
        }
        if let writer { await writer.finishWriting() }
        let received = _hasReceivedSamples.withLock { $0 }
        let url = writer?.status == .completed && received ? outputURL : nil
        if url == nil, let outputURL { try? FileManager.default.removeItem(at: outputURL) }
        audioQueue.sync {
            self.assetWriter = nil
            self.assetWriterInput = nil
        }
        clearPCMBuffer()
        recordingApp = nil
        outputURL = nil
        return url
    }

    func cancelRecording() {
        guard state == .recording else { return }
        state = .saving
        timer?.invalidate()
        timer = nil
        stopMeetingMonitor()
        stopAudioWatchdog()
        audioQueue.sync { self.mixTimer?.cancel(); self.mixTimer = nil }
        Task { @MainActor in
            activeStreamID.withLock { $0 = nil }
            if let stream { try? await stream.stopCapture() }
            stream = nil
            stopMicrophoneCapture()
            audioQueue.sync {
                self.endAudioTimeline()
                self.assetWriter?.cancelWriting()
                self.assetWriter = nil
                self.assetWriterInput = nil
            }
            if let url = outputURL { try? FileManager.default.removeItem(at: url) }
            outputURL = nil
            clearPCMBuffer()
            recordingApp = nil
            state = .ready
            recordingDuration = 0
        }
    }

    // MARK: - Microphone Capture

    private func startMicrophoneCapture(sessionID: UUID, reduceEcho: Bool) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        if reduceEcho {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
                inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(
                    enableAdvancedDucking: false, duckingLevel: .min)
            } catch {
                throw Self.captureError("Speaker echo reduction is unavailable: \(error.localizedDescription). Try turning off Reduce speaker echo.")
            }
        }
        // Query AFTER enabling voice processing, which can change the format.
        let hwFormat = inputNode.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0,
              let converter = AVAudioConverter(from: hwFormat, to: Self.pcmSourceFormat) else {
            throw Self.captureError("No usable microphone input is available")
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, time in
            guard let self, time.isHostTimeValid else { return }
            let timestamp = AVAudioTime.seconds(forHostTime: time.hostTime)
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 48000 / hwFormat.sampleRate)) + 1
            guard let converted = AVAudioPCMBuffer(pcmFormat: Self.pcmSourceFormat, frameCapacity: capacity) else { return }
            var conversionError: NSError?
            var consumed = false
            converter.convert(to: converted, error: &conversionError) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard conversionError == nil, converted.frameLength > 0,
                  let data = converted.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: data, count: Int(converted.frameLength)))
            self.audioQueue.async {
                guard self.captureSessionID == sessionID else { return }
                self.mixer?.append(samples, at: timestamp - self.timelineOrigin, source: .microphone)
            }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            engine.stop()
            throw error
        }
        audioEngine = engine
        engineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self, weak engine] _ in
            guard let self, let engine, self.audioEngine === engine, self.state == .recording else { return }
            self.stopMicrophoneCapture()
            do {
                try self.startMicrophoneCapture(sessionID: sessionID, reduceEcho: reduceEcho)
                self.error = nil
            } catch {
                self.microphoneStatus = "Microphone unavailable"
                self.error = "Microphone stopped after an audio device change: \(error.localizedDescription). System audio is still recording."
            }
        }
    }

    private func stopMicrophoneCapture() {
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
    }

    // MARK: - Audio Timeline (audioQueue only)

    private func endAudioTimeline() {
        mixTimer?.cancel()
        mixTimer = nil
        captureSessionID = nil
        mixer = nil
    }

    private func renderAudio(until hostTime: TimeInterval, flush: Bool = false) {
        guard let mixer, let input = assetWriterInput, !writeFailureReported else { return }
        let endFrame = max(0, Int((hostTime - timelineOrigin) * 48000))
        var position = mixer.nextFrame
        while position < endFrame {
            let count = min(RecordingAudioMixer.blockSize, endFrame - position)
            if !flush && count < RecordingAudioMixer.blockSize { break }
            guard input.isReadyForMoreMediaData else {
                if assetWriter?.status == .failed || flush || endFrame - position > 48000 * 5 {
                    reportWriteFailure("Recording could not keep up with saving audio. Finish this recording and check available disk space.")
                }
                return
            }
            guard let samples = self.mixer?.render(frameCount: count),
                  let buffer = Self.makeAudioBuffer(samples, frame: position) else {
                reportWriteFailure("Could not prepare audio for saving.")
                return
            }
            guard input.append(buffer) else {
                reportWriteFailure(assetWriter?.error?.localizedDescription ?? "Could not save recorded audio.")
                return
            }
            _hasReceivedSamples.withLock { $0 = true }
            accumulatePCMSamples(from: buffer)
            position += count
        }
    }

    private func reportWriteFailure(_ message: String) {
        writeFailureReported = true
        DispatchQueue.main.async { self.error = message }
    }

    static func makeAudioBuffer(_ samples: [Float], frame: Int) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        let byteCount = samples.count * MemoryLayout<Float>.size
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: byteCount, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let status = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard status == noErr else { return nil }
        var buffer: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault,
            dataBuffer: block, formatDescription: Self.pcmSourceFormat.formatDescription,
            sampleCount: samples.count, presentationTimeStamp: CMTime(value: Int64(frame), timescale: 48000),
            packetDescriptions: nil, sampleBufferOut: &buffer) == noErr else { return nil }
        return buffer
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[AudioRecorder] SCStream stopped with error: \(error)")
        guard activeStreamID.withLock({ $0 == ObjectIdentifier(stream) }) else { return }
        DispatchQueue.main.async { self.restartStream() }
    }

    // MARK: - Audio Watchdog

    /// A repeating main-run-loop timer scheduled in `.common` modes, so it keeps
    /// firing during modal sessions (e.g. the Zoom meeting-ended NSAlert) — the
    /// default mode pauses there, which froze the duration display and stall
    /// watchdog for as long as the alert stayed open.
    private static func commonModeTimer(interval: TimeInterval, _ fire: @escaping () -> Void) -> Timer {
        let t = Timer(timeInterval: interval, repeats: true) { _ in fire() }
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    private func startAudioWatchdog() {
        lastAudioBufferTime.withLock { $0 = Date() }
        audioWatchdogTimer = Self.commonModeTimer(interval: 5.0) { [weak self] in
            self?.checkAudioStall()
        }
    }

    private func stopAudioWatchdog() {
        audioWatchdogTimer?.invalidate()
        audioWatchdogTimer = nil
    }

    private func checkAudioStall() {
        guard state == .recording, !isRestartingStream else { return }
        let lastTime = lastAudioBufferTime.withLock { $0 }
        let elapsed = Date().timeIntervalSince(lastTime)
        if elapsed > Self.audioStallThreshold {
            print("[AudioRecorder] audio stall detected: no buffers for \(String(format: "%.1f", elapsed))s, restarting stream")
            restartStream()
        }
    }

    private func restartStream() {
        guard state == .recording, !isRestartingStream else { return }
        isRestartingStream = true
        let sessionID = audioQueue.sync { captureSessionID }

        Task { @MainActor in
            defer { isRestartingStream = false }
            // Stop the old stream
            if let oldStream = self.stream {
                try? await oldStream.stopCapture()
                self.stream = nil
            }

            guard state == .recording, audioQueue.sync(execute: { captureSessionID == sessionID }) else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard state == .recording, audioQueue.sync(execute: { captureSessionID == sessionID }),
                      let display = content.displays.first else { return }
                let newStream = try makeStream(display: display, app: recordingApp)
                self.stream = newStream
                activeStreamID.withLock { $0 = ObjectIdentifier(newStream) }
                try await newStream.startCapture()
                guard state == .recording else {
                    try? await newStream.stopCapture()
                    return
                }
                self.lastAudioBufferTime.withLock { $0 = Date() }

                print("[AudioRecorder] stream restarted successfully")
            } catch {
                print("[AudioRecorder] stream restart failed: \(error)")
                if state == .recording {
                    self.error = "System audio capture interrupted: \(error.localizedDescription)"
                }
            }

        }
    }

    // MARK: - Zoom Meeting Monitor

    private func startMeetingMonitor(app: SCRunningApplication) {
        guard Self.zoomBundleIDs.contains(app.bundleIdentifier) else { return }
        recordingPID = app.processID
        meetingStarted = false
        meetingEnded = false

        meetingMonitorTimer = Self.commonModeTimer(interval: 10.0) { [weak self] in
            self?.checkZoomMeetingWindows()
        }
    }

    private func stopMeetingMonitor() {
        meetingMonitorTimer?.invalidate()
        meetingMonitorTimer = nil
        recordingPID = nil
        meetingStarted = false
    }

    private func checkZoomMeetingWindows() {
        guard let pid = recordingPID else { return }

        // Run the blocking ps check on a background thread to avoid stalling the main thread.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            // Check if Zoom's CptHost subprocess is running — it only exists during an active call.
            let hasMeeting = self.zoomHasActiveCall(parentPID: pid)

            DispatchQueue.main.async {
                if hasMeeting {
                    self.meetingStarted = true
                } else if self.meetingStarted {
                    self.meetingMonitorTimer?.invalidate()
                    self.meetingMonitorTimer = nil
                    self.meetingEnded = true
                    self.onMeetingEnded?()
                }
            }
        }
    }

    /// Returns true if Zoom's CptHost (call/meeting host) subprocess is running under the given parent PID.
    /// Uses Darwin syscalls instead of spawning a /bin/ps subprocess.
    private func zoomHasActiveCall(parentPID: pid_t) -> Bool {
        var childPIDs = [pid_t](repeating: 0, count: 128)
        let byteCount = proc_listchildpids(parentPID, &childPIDs,
            Int32(childPIDs.count * MemoryLayout<pid_t>.size))
        guard byteCount > 0 else { return false }
        let childCount = Int(byteCount) / MemoryLayout<pid_t>.size
        for i in 0..<childCount {
            var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if proc_pidpath(childPIDs[i], &pathBuf, UInt32(MAXPATHLEN)) > 0 {
                if String(cString: pathBuf).contains("CptHost") { return true }
            }
        }
        return false
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, activeStreamID.withLock({ $0 == ObjectIdentifier(stream) }),
              sampleBuffer.isValid, sampleBuffer.numSamples > 0,
              let block = CMSampleBufferGetDataBuffer(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return }
        // The stream is configured for mono 48 kHz Float32 PCM.
        guard format.pointee.mSampleRate == 48000, format.pointee.mChannelsPerFrame == 1,
              format.pointee.mBitsPerChannel == 32,
              format.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return }
        lastAudioBufferTime.withLock { $0 = Date() }
        var samples = [Float](repeating: 0, count: sampleBuffer.numSamples)
        let status = samples.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        }
        guard status == noErr else { return }
        mixer?.append(samples, at: sampleBuffer.presentationTimeStamp.seconds - timelineOrigin, source: .system)
    }

    /// Extracts Float32 samples from a CMSampleBuffer (48kHz) and resamples to 16kHz
    /// via AVAudioConverter (applies anti-alias filter) for whisper.cpp.
    private func accumulatePCMSamples(from sampleBuffer: CMSampleBuffer) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let dataPointer, totalLength > 0 else { return }

        let sampleCount = totalLength / MemoryLayout<Float>.size
        guard sampleCount > 0, let converter = pcmResampler else { return }

        let floatPtr = UnsafeRawPointer(dataPointer).bindMemory(to: Float.self, capacity: sampleCount)

        guard let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: Self.pcmSourceFormat, frameCapacity: AVAudioFrameCount(sampleCount)),
              let inputChannel = inputBuffer.floatChannelData?[0] else { return }
        memcpy(inputChannel, floatPtr, sampleCount * MemoryLayout<Float>.size)
        inputBuffer.frameLength = AVAudioFrameCount(sampleCount)

        // 48000 / 16000 = 3; +1 guards against rounding on non-multiples of 3.
        let outputCapacity = AVAudioFrameCount(sampleCount / 3 + 1)
        guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: Self.pcmTargetFormat, frameCapacity: outputCapacity) else { return }

        var convertError: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &convertError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        guard convertError == nil, outputBuffer.frameLength > 0,
              let outputChannel = outputBuffer.floatChannelData?[0] else { return }

        let resampled = Array(UnsafeBufferPointer(start: outputChannel, count: Int(outputBuffer.frameLength)))
        pcmState.withLock { state in
            state.buffer.append(contentsOf: resampled)
        }
    }

    // MARK: - Output URL

    private func makeOutputURL(appName: String) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let recordingsDir = appSupport.appendingPathComponent("WhisperASR/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd HH'h'"
        let timestamp = df.string(from: Date())
        let baseName: String
        if let custom = customRecordingName, !custom.isEmpty {
            let sanitized = custom.replacingOccurrences(of: "/", with: "-")
            baseName = "\(timestamp) \(sanitized)"
        } else {
            let sanitized = appName.replacingOccurrences(of: "/", with: "-")
            baseName = "\(timestamp) \(sanitized)"
        }
        var url = recordingsDir.appendingPathComponent("\(baseName).m4a")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = recordingsDir.appendingPathComponent("\(baseName) \(counter).m4a")
            counter += 1
        }
        return url
    }

    // MARK: - System Preferences

    func openSystemPreferences() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}
