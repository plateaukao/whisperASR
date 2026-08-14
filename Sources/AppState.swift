import Foundation
import Observation

@Observable
class AppState {
    var items: [TranscriptionItem] = []
    var selectedItemID: UUID?

    // Live transcription state
    var liveSegments: [TranscriptionSegment] = []
    var isLiveTranscribing = false
    var enableLiveTranscription = true

    // Inline error banners surfaced in RecordingView. Nil when no error.
    var liveError: String?
    var liveTranslationError: String?

    /// A short-lived, auto-dismissing toast for translation errors in the main
    /// window (e.g. expired/invalid API key, failed API call). Deduplicated and
    /// rate-limited so a stream of identical failures can't spam the user.
    var transientToast: String?
    private var toastDismissTask: Task<Void, Never>?
    /// Monotonic-ish marker for the last toast shown, used to suppress repeats.
    private var lastToastText: String?

    // Live translation state (per-segment)
    var liveTranslatedSegments: [String] = []
    var enableLiveTranslation = false
    /// User-controlled pause for live translation (e.g. the speaker switched to
    /// the listener's native language). Distinct from `translationAuthPaused`,
    /// which is an error-driven stop. While paused, no API calls are made; on
    /// resume, segments spoken during the pause are skipped so only new speech
    /// is translated.
    var liveTranslationPaused = false
    private var liveTranslatedSourceTexts: [String] = []  // tracks what text each translation was for
    /// Parallel to liveTranslatedSegments: number of consecutive chunks a segment's
    /// source text has been stable. Sealed (>= sealThreshold) segments are never retranslated.
    private var liveTranslatedSealCount: [Int] = []
    private static let sealThreshold = 3

    private let service = TranscriptionService()
    private var isTranscribing = false
    private var liveTranscriptionTask: Task<Void, Never>?
    private var liveTranslationTask: Task<Void, Never>?
    /// Single-slot queue: each snapshot supersedes the previous one (they are cumulative),
    /// so keeping a queue of old snapshots was pure wasted work. `countsSeals` is
    /// true for seal-anchored snapshots — only those advance the translation seal
    /// counts, so the faster interim passes can't prematurely lock a segment.
    private var pendingTranslationSnapshot: (segments: [TranscriptionSegment], countsSeals: Bool)?
    private var isTranslationWorkerRunning = false
    private var translationFailureCount = 0
    /// Set when translation is paused due to an auth error; cleared on next start.
    private var translationAuthPaused = false
    private var lastAutoSaveTime: Date = .distantPast

    /// Maximum chunk duration sent to whisper (30 seconds at 16kHz).
    /// Caps processing time so the loop never snowballs.
    private static let maxChunkSamples = 16000 * 30
    /// When speech runs continuously past this without a pause (12s at 16kHz), force a chunk cut at
    /// the live tail rather than waiting longer. Kept well under `maxChunkSamples` so the live tail
    /// is always transcribed and no audio is silently dropped.
    private static let forceChunkSamples = 16000 * 12
    /// Minimum spacing between interim (mid-utterance) live-translation passes.
    /// Seal-anchored passes are not throttled. Streaming engines like Nemotron
    /// finish transcription passes in well under a second, so this is what sets
    /// the effective translation cadence; whisper's slower passes self-limit.
    private static let interimTranslationInterval: TimeInterval = 2.0

    init() {
        items = TranscriptionStore.loadAll()
        selectedItemID = items.first?.id
        // Auto-resume any pending items restored from disk
        if items.contains(where: { $0.status == .pending }) {
            startNextTranscription()
        }
        // Share the single loaded model with the OpenAI-compatible API server and
        // start it if the user left it enabled.
        Task { @MainActor [service] in
            APIServer.shared.attach(service: service)
            if UserDefaults.standard.bool(forKey: APIServer.enabledKey) {
                APIServer.shared.start()
            }
        }
    }

    var selectedItem: TranscriptionItem? {
        items.first { $0.id == selectedItemID }
    }

    func addFile(url: URL) {
        guard !items.contains(where: { $0.fileURL == url }) else {
            selectedItemID = items.first { $0.fileURL == url }?.id
            return
        }

        let item = TranscriptionItem(fileURL: url)
        items.insert(item, at: 0)
        selectedItemID = item.id
        TranscriptionStore.save(item)
        enqueueTranscription(for: item)
    }

    func retranscribe(_ item: TranscriptionItem) {
        cancelDiarization(for: item)
        item.segments = []
        item.fullText = ""
        item.progress = 0
        item.translatedSegments = []
        item.translationLanguage = nil
        enqueueTranscription(for: item)
    }

    func renameItem(_ item: TranscriptionItem, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Preserve the file extension
        let ext = item.fileURL.pathExtension
        let nameWithExt = trimmed.hasSuffix(".\(ext)") ? trimmed : "\(trimmed).\(ext)"

        // Rename the actual file on disk; only adopt the new URL if the move
        // succeeded (moveItem also fails when the destination already exists).
        // Items without an audio file (e.g. recovered transcripts) just get a
        // new display name.
        let newURL = item.fileURL.deletingLastPathComponent().appendingPathComponent(nameWithExt)
        if newURL != item.fileURL, FileManager.default.fileExists(atPath: item.fileURL.path) {
            do {
                try FileManager.default.moveItem(at: item.fileURL, to: newURL)
            } catch {
                Task { @MainActor in
                    self.showToast("Couldn't rename \"\(item.fileName)\": \(error.localizedDescription)")
                }
                return
            }
            item.fileURL = newURL
        }
        item.fileName = nameWithExt
        TranscriptionStore.save(item)
    }

    /// Add a file with pre-existing live transcription results (skip re-transcription).
    @discardableResult
    func addFileWithLiveResults(url: URL, segments: [TranscriptionSegment], fullText: String,
                                translatedSegments: [String] = [], translationLanguage: String? = nil) -> TranscriptionItem {
        let item = TranscriptionItem(fileURL: url)
        item.segments = segments
        item.fullText = fullText
        item.translatedSegments = translatedSegments
        item.translationLanguage = translationLanguage
        item.status = .completed
        items.insert(item, at: 0)
        selectedItemID = item.id
        TranscriptionStore.save(item)
        return item
    }

    /// Stop live transcription and the recorder, then file the finished recording.
    /// Shared by the Finish Recording button and the Zoom meeting-ended flow.
    /// If the audio file failed to save but live transcription produced a
    /// transcript, the transcript is kept as an audio-less item instead of
    /// being silently dropped with the recording.
    @MainActor
    func finishRecording(recorder: AudioRecorder) async {
        let segments = liveSegments
        let fullText = segments.map { $0.text }.joined()
        let translations = liveTranslatedSegments
        let lang: String? = !translations.isEmpty
            ? UserDefaults.standard.string(forKey: "targetLanguage") : nil
        let hadLiveResults = isLiveTranscribing && !segments.isEmpty

        stopLiveTranscription()
        let url = await recorder.stopRecording()

        if let url {
            // Live results from a dedicated (usually smaller/faster) live model
            // are a draft: send the saved recording through the normal pipeline
            // so the main model produces the final transcript. Only when live
            // ran on the same model are its results kept as final.
            let liveModelDiffers = !ModelManager.shared.liveFileName.isEmpty
                && ModelManager.shared.liveFileName != ModelManager.shared.selectedFileName
            if hadLiveResults && !liveModelDiffers {
                addFileWithLiveResults(url: url, segments: segments, fullText: fullText,
                                       translatedSegments: translations, translationLanguage: lang)
            } else {
                addFile(url: url)
            }
        } else if hadLiveResults {
            let item = addFileWithLiveResults(
                url: URL(fileURLWithPath: "/unsaved-recording-\(UUID().uuidString)"),
                segments: segments, fullText: fullText,
                translatedSegments: translations, translationLanguage: lang)
            item.fileName = "Recording \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)) (audio not saved)"
            TranscriptionStore.save(item)
        }
        recorder.state = .idle
    }

    // MARK: - Translate Completed Transcription

    /// Show a transient, auto-dismissing toast. Repeats of the same message are
    /// ignored (the timer just restarts) so a continuously-failing translation
    /// queue surfaces the problem once rather than flickering on every retry.
    @MainActor
    func showToast(_ text: String, duration: Duration = .seconds(6)) {
        transientToast = text
        lastToastText = text
        toastDismissTask?.cancel()
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // Only clear if it's still the same message we scheduled.
                if self?.lastToastText == text { self?.transientToast = nil }
            }
        }
    }

    func translateItem(_ item: TranscriptionItem, targetLanguage: String) {
        guard !item.segments.isEmpty, !item.isTranslating else { return }
        item.isTranslating = true
        item.translatedSegments = Array(repeating: "", count: item.segments.count)
        item.translationLanguage = targetLanguage

        // @MainActor: `item` is observed by SwiftUI, so every mutation below must
        // land on the main actor; only the translation API calls suspend off it.
        Task { @MainActor in
            let texts = item.segments.map { $0.text.trimmingCharacters(in: .whitespaces) }
            let batchSize = 20
            var transientFailures = 0

            batchLoop: for batchStart in stride(from: 0, to: texts.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, texts.count)
                let batch = Array(texts[batchStart..<batchEnd])

                let contextStart = max(0, batchStart - 2)
                let contextPairs: [(original: String, translated: String)] = (contextStart..<batchStart).compactMap { i in
                    guard !texts[i].isEmpty, !item.translatedSegments[i].isEmpty else { return nil }
                    return (original: texts[i], translated: item.translatedSegments[i])
                }

                do {
                    let translations = try await TranslationService.translateSegmentsWithOpenAI(
                        segmentTexts: batch,
                        targetLanguage: targetLanguage,
                        previousTranslations: contextPairs
                    )
                    for (offset, translation) in translations.enumerated() {
                        item.translatedSegments[batchStart + offset] = translation
                    }
                } catch let err as TranslationError {
                    print("[Translation] batch error: \(err)")
                    switch err {
                    case .authFailed, .invalidEndpoint, .unavailable:
                        // Not retriable — stop hammering the API and report it once.
                        self.showToast(err.errorDescription ?? "Translation failed")
                        break batchLoop
                    default:
                        transientFailures += 1
                    }
                } catch {
                    print("[Translation] batch error: \(error)")
                    transientFailures += 1
                }
            }

            // Some batches failed transiently (network/server/rate-limit) but we
            // kept going; let the user know the result is incomplete.
            if transientFailures > 0 {
                self.showToast("Translation incomplete — \(transientFailures) section\(transientFailures == 1 ? "" : "s") couldn't be translated. Check your network or API settings.")
            }

            item.isTranslating = false
            TranscriptionStore.save(item)
        }
    }

    func clearTranslation(_ item: TranscriptionItem) {
        item.translatedSegments = []
        item.translationLanguage = nil
        TranscriptionStore.save(item)
    }

    // MARK: - Speaker Diarization

    /// In-flight diarization passes by item id, so removing or re-transcribing an
    /// item cancels its pass instead of letting it label a transcript that no
    /// longer wants it.
    private var diarizationTasks: [UUID: Task<Void, Never>] = [:]

    /// Runs diarization over a finished transcript and labels its segments with
    /// who spoke. Known voices are enrolled first so recognized speakers come back
    /// named instead of numbered; `knownSpeakerIDs` narrows that to the people the
    /// user said are in the recording — nil means the whole library, an empty
    /// array means enroll nobody ("none of these people are present").
    ///
    /// @MainActor: `item` is observed by SwiftUI, so every mutation below must
    /// land on the main actor; only the engine itself suspends off it.
    @MainActor
    func diarizeItem(_ item: TranscriptionItem, knownSpeakerIDs: [UUID]? = nil) {
        guard !item.segments.isEmpty, !item.isDiarizing else { return }
        item.isDiarizing = true
        item.diarizationProgress = 0
        item.diarizationError = nil

        let knownSpeakers = SpeakerLibrary.knownSpeakerSamples(for: knownSpeakerIDs)
        let provider = DiarizationService.provider()

        diarizationTasks[item.id] = Task { @MainActor in
            defer {
                item.isDiarizing = false
                item.diarizationProgress = 0
                diarizationTasks[item.id] = nil
            }
            do {
                let result = try await provider.diarize(
                    audioURL: item.fileURL,
                    knownSpeakers: knownSpeakers
                ) { progress in
                    Task { @MainActor in
                        item.diarizationProgress = progress
                    }
                }
                // Extraction is the slow part of enrollment; cache what this pass
                // computed so the next one reuses it.
                SpeakerLibrary.cacheEmbeddings(result.extractedEmbeddings)
                item.segments = DiarizationService.assignSpeakers(to: item.segments,
                                                                  turns: result.turns)
                TranscriptionStore.save(item)
            } catch is CancellationError {
                // The item was removed or re-transcribed — nothing to report.
            } catch {
                print("[Diarization] \(provider.displayName) failed: \(error)")
                item.diarizationError = error.localizedDescription
                self.showToast("Couldn't identify speakers: \(error.localizedDescription)")
            }
        }
    }

    private func cancelDiarization(for item: TranscriptionItem) {
        diarizationTasks[item.id]?.cancel()
        diarizationTasks[item.id] = nil
    }

    func shutdown() {
        service.shutdown()
    }

    func removeItem(_ item: TranscriptionItem) {
        cancelDiarization(for: item)
        items.removeAll { $0.id == item.id }
        TranscriptionStore.delete(item)
        if selectedItemID == item.id {
            selectedItemID = items.first?.id
        }
    }

    private func enqueueTranscription(for item: TranscriptionItem) {
        item.status = .pending
        if !isTranscribing {
            startNextTranscription()
        }
    }

    private func startNextTranscription() {
        guard let item = items.first(where: { $0.status == .pending }) else {
            isTranscribing = false
            return
        }
        isTranscribing = true
        item.status = .transcribing
        item.progress = 0
        item.transcriptionStartTime = Date()

        Task.detached { [service] in
            do {
                let result = try await service.transcribe(fileURL: item.fileURL) { progress in
                    Task { @MainActor in
                        item.progress = progress
                    }
                }
                await MainActor.run {
                    item.segments = result.segments
                    item.fullText = result.text
                    item.status = .completed
                    TranscriptionStore.save(item)
                }
            } catch {
                await MainActor.run {
                    item.status = .failed(error.localizedDescription)
                    TranscriptionStore.save(item)
                }
            }
            await MainActor.run { [weak self] in
                self?.startNextTranscription()
            }
        }
    }

    // MARK: - Live Transcription During Recording

    /// Start periodic live transcription from the AudioRecorder's accumulated PCM buffer.
    func startLiveTranscription(recorder: AudioRecorder) {
        liveSegments = []
        liveError = nil
        liveTranslationError = nil
        liveTranslatedSealCount = []
        translationFailureCount = 0
        translationAuthPaused = false
        liveTranslationPaused = false
        isLiveTranscribing = true

        liveTranscriptionTask = Task { [weak self] in
            guard let self else { return }

            // Pre-load the model and wait for it — avoids model loading latency on first chunk.
            // Surface load failures so the user isn't stuck at a silent "Waiting for audio...".
            do {
                try await self.service.preloadLiveModel()
            } catch {
                await MainActor.run {
                    self.liveError = "Couldn't load transcription model: \(error.localizedDescription)"
                    self.isLiveTranscribing = false
                }
                return
            }
            guard !Task.isCancelled else { return }

            // Partial/final streaming model:
            //  - Every pass re-transcribes the unsealed *tail* and shows it immediately, so the
            //    in-progress sentence appears within ~1s (no waiting for a pause).
            //  - Segments before the last silence pause are *sealed* (final) — they stop changing
            //    and are never re-transcribed, which keeps boundaries clean and translation steady.
            var sealedSegments: [TranscriptionSegment] = []
            var sealedSampleCount = 0
            // Whether the seal boundary fell inside a pause (clean). A clean boundary needs no
            // left-context overlap; a forced mid-speech seal does, to avoid clipping the cut word.
            var sealedClean = true
            var consecutiveSilenceCount = 0
            var lastTranscribedTotal = 0
            // Interim-translation debounce (see interimTranslationInterval).
            var lastInterimTranslation = Date.distantPast
            var lastTranslatedSnapshotText = ""

            // Silence-scan tuning (16kHz): 100ms frames; a run of >=3 (~300ms) counts as a pause.
            let frameSamples = 1600
            let minSilenceFrames = 3
            let silenceThreshold: Float = 0.001
            let contextSamples = 16000   // 1s left-context, used only after a forced seal

            // The loop awaits each transcribeChunk before iterating, so passes never overlap.
            while !Task.isCancelled {
                let totalSamples = recorder.accumulatedSampleCount
                let tailCount = totalSamples - sealedSampleCount

                // Need >=0.5s of unsealed audio and >=0.3s of new audio since the last pass —
                // keeps the live tail fresh without re-transcribing identical audio in a tight loop.
                guard tailCount >= 8000, totalSamples - lastTranscribedTotal >= 4800 else {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }

                // If the whole unsealed tail is silence, seal forward and show only sealed text.
                let rms = recorder.rmsEnergy(from: sealedSampleCount, count: tailCount)
                guard rms > silenceThreshold else {
                    sealedSampleCount = totalSamples
                    sealedClean = true
                    lastTranscribedTotal = totalSamples
                    recorder.trimSamples(upTo: max(0, sealedSampleCount - contextSamples))
                    consecutiveSilenceCount += 1
                    let snapshot = sealedSegments
                    await MainActor.run {
                        self.liveSegments = snapshot
                        self.throttledAutoSave()
                    }
                    try? await Task.sleep(for: .milliseconds(consecutiveSilenceCount >= 2 ? 1000 : 500))
                    continue
                }
                consecutiveSilenceCount = 0

                // Re-transcribe the unsealed tail for live display. After a clean (silence) seal the
                // boundary needs no overlap; after a forced seal, re-transcribe 1s of context and
                // dedup so the cut word isn't dropped.
                let useOverlap = !sealedClean
                var tailStart = useOverlap ? max(0, sealedSampleCount - contextSamples) : sealedSampleCount

                // Defensive: bound the tail to whisper's 30s window. Only reachable if a pass
                // stalled badly; surface it instead of silently mis-transcribing.
                if totalSamples - tailStart > Self.maxChunkSamples {
                    print("[AppState] live tail \(totalSamples - tailStart) samples exceeds maxChunkSamples — transcribing only the most recent (older audio skipped)")
                    await MainActor.run {
                        self.liveError = "Transcription is falling behind — some audio may be skipped."
                    }
                    tailStart = totalSamples - Self.maxChunkSamples
                }

                let chunk = recorder.getSamples(from: tailStart, upTo: totalSamples)
                guard !chunk.isEmpty else {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                lastTranscribedTotal = totalSamples
                let timeOffset = Double(tailStart) / 16000.0

                // Cap the wait so a GPU/Metal hang doesn't deadlock the live loop.
                // Generous: 4× chunk duration, minimum 60s.
                let chunkSeconds = Double(chunk.count) / 16000.0
                let timeoutSeconds = max(60.0, chunkSeconds * 4.0)
                do {
                    let result = try await Self.withTimeout(seconds: timeoutSeconds) {
                        try await self.service.transcribeChunk(samples: chunk)
                    }

                    // Offset timestamps to match position in the full stream.
                    let tailSegments = result.segments.map { seg in
                        TranscriptionSegment(
                            start: seg.start + timeOffset,
                            end: seg.end.map { $0 + timeOffset },
                            text: seg.text
                        )
                    }

                    // Combine sealed (final) + freshly transcribed tail (interim) for display.
                    let tailStartTime = Double(tailStart) / 16000.0
                    let kept = sealedSegments.filter { $0.start < tailStartTime }
                    var combined = kept
                    for seg in tailSegments {
                        var text = seg.text
                        if useOverlap, let lastText = combined.last?.text {
                            text = Self.trimOverlap(previous: lastText, current: text)
                        }
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            combined.append(TranscriptionSegment(
                                start: seg.start, end: seg.end, text: text))
                        }
                    }

                    // Advance the seal: to a trailing pause (clean), or forced once the tail has
                    // grown past the cap without one. Everything before it becomes final.
                    let silenceCut = recorder.lastSilenceCut(
                        searchFrom: sealedSampleCount, searchTo: totalSamples,
                        frameSamples: frameSamples, silenceThreshold: silenceThreshold,
                        minSilenceFrames: minSilenceFrames)
                    var newSeal = sealedSampleCount
                    var newSealClean = sealedClean
                    if let cut = silenceCut, cut - sealedSampleCount >= 8000 {
                        newSeal = cut; newSealClean = true
                    } else if tailCount >= Self.forceChunkSamples {
                        newSeal = totalSamples; newSealClean = false
                    }

                    var sealAdvanced = false
                    if newSeal > sealedSampleCount {
                        let sealTime = Double(newSeal) / 16000.0
                        sealedSegments = combined.filter { $0.start < sealTime }
                        sealedSampleCount = newSeal
                        sealedClean = newSealClean
                        sealAdvanced = true
                        // Nothing behind a clean (silence) seal is needed again; keep 1s behind a
                        // forced seal for the next pass's overlap.
                        recorder.trimSamples(upTo: max(0, newSeal - (newSealClean ? 0 : contextSamples)))
                    }

                    let snapshot = combined
                    await MainActor.run {
                        self.liveSegments = snapshot
                        self.throttledAutoSave()
                    }
                    // Seal-anchored passes always translate. Between seals, also translate the
                    // in-progress tail on a debounce so translations keep up with fast streaming
                    // engines — the worker is single-flight/latest-wins and the dirty-scan skips
                    // unchanged text, so this stays cheap and flicker is bounded to the tail.
                    if self.enableLiveTranslation && !snapshot.isEmpty {
                        let targetLang = UserDefaults.standard.string(forKey: "targetLanguage") ?? ""
                        let snapshotText = snapshot.map(\.text).joined(separator: "\n")
                        let interimDue = Date().timeIntervalSince(lastInterimTranslation) >= Self.interimTranslationInterval
                            && snapshotText != lastTranslatedSnapshotText
                        if !targetLang.isEmpty && (sealAdvanced || interimDue) {
                            lastInterimTranslation = Date()
                            lastTranslatedSnapshotText = snapshotText
                            await MainActor.run {
                                self.enqueueLiveTranslation(snapshot, countsSeals: sealAdvanced)
                            }
                        }
                    }
                } catch is TimeoutError {
                    print("[AppState] live transcription chunk timed out after \(timeoutSeconds)s")
                    await MainActor.run {
                        self.liveError = "Transcription is slow — the model or GPU may be stuck. Continuing with next chunk."
                    }
                } catch {
                    print("[AppState] live transcription chunk error: \(error)")
                }

                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Stop the live transcription timer. Called when recording ends.
    func stopLiveTranscription() {
        liveTranscriptionTask?.cancel()
        liveTranscriptionTask = nil
        // Free the dedicated live model (if one was loaded) — the final file
        // transcription uses the main model.
        service.unloadLiveModel()
        liveTranslationTask?.cancel()
        liveTranslationTask = nil
        pendingTranslationSnapshot = nil
        isTranslationWorkerRunning = false
        translationFailureCount = 0
        translationAuthPaused = false
        isLiveTranscribing = false
        liveError = nil
        liveTranslationError = nil
        // Clear live results (the final file transcription will replace them)
        liveSegments = []
        liveTranslatedSegments = []
        liveTranslatedSourceTexts = []
        liveTranslatedSealCount = []
        enableLiveTranslation = false
        liveTranslationPaused = false
        removeLiveRecoveryFile()
    }

    /// Punctuation/whitespace whisper sprinkles at chunk edges; ignored when matching an overlap.
    private static let overlapTrimChars = CharacterSet(
        charactersIn: "，。、！？；：「」『』（）()【】［］…—~,.!?;:'\" \t\n")

    /// Trim the leading portion of `current` that duplicates the trailing portion of `previous`.
    /// Produced when a forced chunk re-transcribes the 1s context overlap. The match floor is a
    /// single character (Mandarin is dense — the previous 4-char floor missed most overlaps) and
    /// boundary punctuation/whitespace is stripped so a comma/period whisper added at the cut can't
    /// block the match.
    static func trimOverlap(previous: String, current: String) -> String {
        var source = previous.trimmingCharacters(in: .whitespaces)
        while let last = source.unicodeScalars.last, overlapTrimChars.contains(last) {
            source.unicodeScalars.removeLast()
        }
        var target = Substring(current.trimmingCharacters(in: .whitespaces))
        while let first = target.unicodeScalars.first, overlapTrimChars.contains(first) {
            target = target.dropFirst()
        }
        let maxCheck = min(source.count, target.count)
        guard maxCheck >= 1 else { return current }
        for len in stride(from: maxCheck, through: 1, by: -1) {
            if target.hasPrefix(String(source.suffix(len))) {
                return String(target.dropFirst(len))
            }
        }
        return current
    }

    // MARK: - Live Transcription Auto-Save (crash recovery)

    private static var liveRecoveryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("WhisperASR", isDirectory: true)
            .appendingPathComponent("live_recovery.json")
    }

    private struct LiveRecoveryData: Codable {
        let segments: [TranscriptionSegment]
        let fullText: String
        let translatedSegments: [String]
        let translationLanguage: String?
        let savedAt: Date
    }

    /// Only auto-save at most every 15 seconds to avoid JSON serialization overhead.
    @MainActor
    private func throttledAutoSave() {
        let now = Date()
        guard now.timeIntervalSince(lastAutoSaveTime) >= 15 else { return }
        lastAutoSaveTime = now
        autoSaveLiveTranscription()
    }

    /// Persist current live transcription to a recovery file so data survives a hang or crash.
    @MainActor
    private func autoSaveLiveTranscription() {
        let segments = liveSegments
        let text = segments.map { $0.text }.joined()
        let translations = liveTranslatedSegments
        let lang: String? = !translations.isEmpty
            ? UserDefaults.standard.string(forKey: "targetLanguage") : nil

        // Write on a background queue to avoid blocking the main thread
        Task.detached(priority: .utility) {
            let data = LiveRecoveryData(
                segments: segments, fullText: text,
                translatedSegments: translations, translationLanguage: lang,
                savedAt: Date()
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            guard let json = try? encoder.encode(data) else { return }
            let url = AppState.liveRecoveryURL
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? json.write(to: url, options: .atomic)
        }
    }

    private func removeLiveRecoveryFile() {
        try? FileManager.default.removeItem(at: Self.liveRecoveryURL)
    }

    /// Check if there is a recoverable live transcription from a previous crash/hang.
    var hasLiveRecoveryData: Bool {
        FileManager.default.fileExists(atPath: Self.liveRecoveryURL.path)
    }

    /// Import recovered live transcription as a completed transcription item.
    func importRecoveredTranscription() {
        let url = Self.liveRecoveryURL
        guard let data = try? Data(contentsOf: url),
              let recovery = try? JSONDecoder().decode(LiveRecoveryData.self, from: data)
        else { return }
        let item = TranscriptionItem(
            fileURL: URL(fileURLWithPath: "/recovered-\(ISO8601DateFormatter().string(from: recovery.savedAt))"))
        item.segments = recovery.segments
        item.fullText = recovery.fullText
        item.translatedSegments = recovery.translatedSegments
        item.translationLanguage = recovery.translationLanguage
        item.status = .completed
        item.fileName = "Recovered \(DateFormatter.localizedString(from: recovery.savedAt, dateStyle: .short, timeStyle: .short))"
        items.insert(item, at: 0)
        selectedItemID = item.id
        TranscriptionStore.save(item)
        removeLiveRecoveryFile()
    }

    // MARK: - Live Translation

    /// Queue the latest translation snapshot. Since each snapshot is cumulative
    /// (contains all segments so far), a newer one always supersedes an older one,
    /// so we keep only the most recent. A single worker drains this slot.
    /// Pause or resume live translation on demand. When resuming, everything
    /// spoken during the pause is marked as already handled (sealed) so the
    /// dirty-scan won't retroactively translate the skipped (native-language)
    /// portion — only segments transcribed from here on get translated.
    @MainActor
    func setLiveTranslationPaused(_ paused: Bool) {
        guard liveTranslationPaused != paused else { return }
        liveTranslationPaused = paused
        if paused {
            // Stop calling the API immediately by dropping any queued snapshot.
            pendingTranslationSnapshot = nil
        } else {
            // Seal the current segments so they're not retranslated on resume.
            let texts = liveSegments.map { $0.text.trimmingCharacters(in: .whitespaces) }
            let n = texts.count
            if liveTranslatedSegments.count < n {
                liveTranslatedSegments += Array(repeating: "", count: n - liveTranslatedSegments.count)
            }
            liveTranslatedSourceTexts = texts
            liveTranslatedSealCount = Array(repeating: Self.sealThreshold, count: n)
            // Kick the worker so subsequent segments resume translating.
            if isLiveTranscribing { enqueueLiveTranslation(liveSegments, countsSeals: true) }
        }
    }

    @MainActor
    private func enqueueLiveTranslation(_ segments: [TranscriptionSegment], countsSeals: Bool) {
        guard !translationAuthPaused, !liveTranslationPaused else { return }
        // A superseded seal-anchored snapshot keeps its seal-counting duty: the
        // newer segments are cumulative, so counting seals on them is equivalent.
        let carrySeals = countsSeals || (pendingTranslationSnapshot?.countsSeals ?? false)
        pendingTranslationSnapshot = (segments: segments, countsSeals: carrySeals)
        guard !isTranslationWorkerRunning else { return }
        isTranslationWorkerRunning = true
        liveTranslationTask = Task { [weak self] in
            await self?.drainTranslationQueue()
        }
    }

    private func drainTranslationQueue() async {
        while !Task.isCancelled {
            let next: (segments: [TranscriptionSegment], countsSeals: Bool)? = await MainActor.run { [weak self] in
                guard let self else { return nil }
                if let snapshot = self.pendingTranslationSnapshot {
                    self.pendingTranslationSnapshot = nil
                    return snapshot
                }
                self.isTranslationWorkerRunning = false
                return nil
            }
            guard let (segments, countsSeals) = next else { return }
            if segments.isEmpty { continue }
            let targetLang = UserDefaults.standard.string(forKey: "targetLanguage") ?? ""
            guard !targetLang.isEmpty else { continue }
            await translateLiveSegments(segments, targetLang: targetLang, countsSeals: countsSeals)
        }
        await MainActor.run { self.isTranslationWorkerRunning = false }
    }

    private func translateLiveSegments(_ segments: [TranscriptionSegment], targetLang: String, countsSeals: Bool) async {
        guard !Task.isCancelled else { return }

        // Exponential backoff on repeated failures (500ms, 1s, 2s, ..., capped at 30s).
        let failureCount = await MainActor.run { self.translationFailureCount }
        if failureCount > 0 {
            let delayMs = min(30_000, 500 * Int(pow(2.0, Double(failureCount - 1))))
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard !Task.isCancelled else { return }
        }

        let texts = segments.map { $0.text.trimmingCharacters(in: .whitespaces) }
        let (existing, existingSourceTexts, sealCounts) = await MainActor.run {
            (self.liveTranslatedSegments, self.liveTranslatedSourceTexts, self.liveTranslatedSealCount)
        }

        // Find the first index where the segment text changed or has no translation.
        // Segments in the overlap zone may be re-transcribed with different text,
        // so we need to re-translate from the first divergent segment onward.
        var firstDirtyIndex = min(existing.count, texts.count)
        for i in 0..<min(existing.count, existingSourceTexts.count, texts.count) {
            if texts[i] != existingSourceTexts[i] || existing[i].isEmpty {
                firstDirtyIndex = i
                break
            }
        }

        // Sealed segments are never retranslated — bounds the cascade when whisper's
        // overlap zone shifts an early segment's text yet again after it has stabilized.
        let firstUnsealedIndex: Int = {
            for i in 0..<sealCounts.count {
                if sealCounts[i] < Self.sealThreshold { return i }
            }
            return sealCounts.count
        }()
        let dirtyIndex = max(firstDirtyIndex, firstUnsealedIndex)

        let textsToTranslate = Array(texts.dropFirst(dirtyIndex))
        guard !textsToTranslate.isEmpty else {
            // Nothing to translate, but still need to update seal counts for stable suffix.
            if countsSeals {
                await MainActor.run { self.updateSealCounts(newSourceTexts: texts) }
            }
            return
        }

        // Use up to 2 clean translations before the dirty range as context
        let contextStart = max(0, dirtyIndex - 2)
        let contextPairs: [(original: String, translated: String)] = (contextStart..<dirtyIndex).compactMap { i in
            guard i < texts.count, i < existing.count,
                  !texts[i].isEmpty, !existing[i].isEmpty else { return nil }
            return (original: texts[i], translated: existing[i])
        }

        do {
            let newTranslations = try await TranslationService.translateSegmentsWithOpenAI(
                segmentTexts: textsToTranslate, targetLanguage: targetLang,
                previousTranslations: contextPairs)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.liveTranslatedSegments = Array(existing.prefix(dirtyIndex)) + newTranslations
                self.liveTranslatedSourceTexts = Array(texts.prefix(dirtyIndex)) + textsToTranslate
                if countsSeals {
                    self.updateSealCounts(newSourceTexts: texts)
                }
                self.translationFailureCount = 0
                self.liveTranslationError = nil
            }
        } catch let err as TranslationError {
            print("[Translation] OpenAI error: \(err)")
            await MainActor.run {
                switch err {
                case .authFailed, .invalidEndpoint:
                    // Pause translation entirely — retrying only wastes quota.
                    self.translationAuthPaused = true
                    self.liveTranslationError = err.errorDescription
                    self.pendingTranslationSnapshot = nil
                default:
                    self.translationFailureCount += 1
                    if self.translationFailureCount >= 3 {
                        self.liveTranslationError = err.errorDescription
                    }
                }
                // Pad source-text tracking so next cycle can detect segments still needing translation.
                if self.liveTranslatedSegments.count < texts.count {
                    self.liveTranslatedSegments += Array(repeating: "", count: texts.count - self.liveTranslatedSegments.count)
                    self.liveTranslatedSourceTexts += texts.suffix(texts.count - self.liveTranslatedSourceTexts.count)
                }
            }
        } catch {
            print("[Translation] error: \(error)")
            await MainActor.run {
                self.translationFailureCount += 1
                if self.translationFailureCount >= 3 {
                    self.liveTranslationError = error.localizedDescription
                }
            }
        }
    }

    /// Increment seal count for each segment whose source text matches last cycle; reset on change.
    @MainActor
    private func updateSealCounts(newSourceTexts: [String]) {
        var updated: [Int] = []
        updated.reserveCapacity(newSourceTexts.count)
        for i in 0..<newSourceTexts.count {
            if i < liveTranslatedSealCount.count, i < liveTranslatedSourceTexts.count,
               liveTranslatedSourceTexts[i] == newSourceTexts[i] {
                updated.append(min(Self.sealThreshold, liveTranslatedSealCount[i] + 1))
            } else {
                updated.append(1)
            }
        }
        liveTranslatedSealCount = updated
    }

    // MARK: - Timeout helper

    private struct TimeoutError: Error {}

    /// Run `operation` with a timeout. If it doesn't complete within `seconds`, throws TimeoutError.
    private static func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw TimeoutError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
