import CryptoKit
import Foundation

enum TranscriptionStore {

    // MARK: - Codable DTO

    private struct StoredItem: Codable {
        let id: UUID
        let fileName: String
        let filePath: String
        let segments: [TranscriptionSegment]
        let diarizationSourceSegments: [TranscriptionSegment]?
        let fullText: String
        let dateAdded: Date
        let statusTag: String          // "completed", "failed", "pending"
        let errorMessage: String?
        let translatedSegments: [String]?
        let translationLanguage: String?
        let exportedTextFileName: String?
    }

    struct MigrationResult {
        let migratedCount: Int
        let skippedCount: Int
        let failedCount: Int
        let firstError: String?
    }

    // MARK: - Export Folder Setting

    static let exportFolderPathKey = "transcriptionExportFolderPath"

    /// Default folder where plain-text `.txt` transcripts are auto-saved
    /// alongside the app's internal JSON store.
    static var defaultExportDirectory: URL {
        storeDirectory
    }

    static var customExportFolderPath: String {
        get {
            UserDefaults.standard.string(forKey: exportFolderPathKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty
                || URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
                    == defaultExportDirectory.standardizedFileURL {
                UserDefaults.standard.removeObject(forKey: exportFolderPathKey)
            } else {
                UserDefaults.standard.set(trimmed, forKey: exportFolderPathKey)
            }
        }
    }

    static var exportDirectory: URL {
        let custom = customExportFolderPath
        guard !custom.isEmpty else { return defaultExportDirectory }
        return URL(fileURLWithPath: custom, isDirectory: true)
    }

    static var isUsingDefaultExportDirectory: Bool {
        exportDirectory.standardizedFileURL == defaultExportDirectory.standardizedFileURL
    }

    // MARK: - Directory

    private static var storeDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("WhisperASR", isDirectory: true)
            .appendingPathComponent("Transcriptions", isDirectory: true)
    }

    private static func ensureDirectory() {
        try? FileManager.default.createDirectory(
            at: storeDirectory, withIntermediateDirectories: true
        )
    }

    private static func fileURL(for id: UUID) -> URL {
        storeDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private static var recordingsDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("WhisperASR", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    /// Resolve a stored recording path, healing it if it no longer exists. After
    /// moving to a new Mac the absolute path embeds the old username and breaks;
    /// if a file of the same name sits in the local Recordings folder we re-link
    /// to it. Only kicks in when the original is missing, so files that live
    /// elsewhere (e.g. drag-dropped) are left untouched.
    private static func resolveRecordingURL(storedPath: String) -> URL {
        let original = URL(fileURLWithPath: storedPath)
        if FileManager.default.fileExists(atPath: storedPath) { return original }
        let candidate = recordingsDirectory.appendingPathComponent(original.lastPathComponent)
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        return original
    }

    // MARK: - Save

    static func save(_ item: TranscriptionItem) {
        if item.status == .completed {
            syncExportedText(for: item, in: exportDirectory)
        }
        saveMetadata(item)
    }

    private static func saveMetadata(_ item: TranscriptionItem) {
        ensureDirectory()

        let statusTag: String
        let errorMessage: String?
        switch item.status {
        case .completed:
            statusTag = "completed"
            errorMessage = nil
        case .failed(let msg):
            statusTag = "failed"
            errorMessage = msg
        default:
            statusTag = "pending"
            errorMessage = nil
        }

        let stored = StoredItem(
            id: item.id,
            fileName: item.fileName,
            filePath: item.fileURL.path,
            segments: item.segments,
            diarizationSourceSegments: item.diarizationSourceSegments,
            fullText: item.fullText,
            dateAdded: item.dateAdded,
            statusTag: statusTag,
            errorMessage: errorMessage,
            translatedSegments: item.translatedSegments.isEmpty ? nil : item.translatedSegments,
            translationLanguage: item.translationLanguage,
            exportedTextFileName: item.exportedTextFileName
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(stored) else { return }
        try? data.write(to: fileURL(for: item.id), options: .atomic)
    }

    // MARK: - Plain-Text Auto-Export

    private static func sanitizeExportBaseName(_ rawName: String, fallbackID: UUID) -> String {
        let base = (rawName as NSString).deletingPathExtension
        let cleaned = base
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallbackID.uuidString : cleaned
    }

    private static func matchesBaseName(_ fileName: String, baseName: String) -> Bool {
        if fileName == "\(baseName).txt" { return true }
        let prefix = "\(baseName) ("
        let suffix = ").txt"
        guard fileName.hasPrefix(prefix), fileName.hasSuffix(suffix) else { return false }
        let start = fileName.index(fileName.startIndex, offsetBy: prefix.count)
        let end = fileName.index(fileName.endIndex, offsetBy: -suffix.count)
        guard start < end else { return false }
        return Int(fileName[start..<end]) != nil
    }

    private static func uniqueExportFileName(
        baseName: String,
        in directory: URL,
        ignoring existingFileName: String? = nil
    ) -> String {
        let fm = FileManager.default
        let firstCandidate = "\(baseName).txt"
        if firstCandidate == existingFileName
            || !fm.fileExists(atPath: directory.appendingPathComponent(firstCandidate).path) {
            return firstCandidate
        }
        var counter = 2
        while true {
            let candidate = "\(baseName) (\(counter)).txt"
            if candidate == existingFileName
                || !fm.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
                return candidate
            }
            counter += 1
        }
    }

    /// Writes (or updates) the plain-text `.txt` file for a completed item in
    /// `directory`. Reuses `item.exportedTextFileName` when the item's name
    /// hasn't changed so diarization and speaker-name edits update the file in
    /// place; renames cleanly if the recording was renamed.
    @discardableResult
    private static func syncExportedText(for item: TranscriptionItem, in directory: URL) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("[TranscriptionStore] Couldn't create export directory \(directory.path): \(error)")
            return false
        }

        let baseName = sanitizeExportBaseName(item.fileName, fallbackID: item.id)
        let previousName = item.exportedTextFileName
        let targetName: String
        if let previousName, matchesBaseName(previousName, baseName: baseName) {
            targetName = previousName
        } else {
            targetName = uniqueExportFileName(baseName: baseName, in: directory, ignoring: previousName)
        }

        let targetURL = directory.appendingPathComponent(targetName)
        let text = SubtitleFormatter.plainText(segments: item.segments, fallbackText: item.fullText)
        do {
            try text.write(to: targetURL, atomically: true, encoding: .utf8)
        } catch {
            print("[TranscriptionStore] Couldn't write exported transcript \(targetURL.path): \(error)")
            return false
        }

        if let previousName, previousName != targetName {
            let oldURL = directory.appendingPathComponent(previousName)
            if fm.fileExists(atPath: oldURL.path) {
                try? fm.removeItem(at: oldURL)
            }
        }
        item.exportedTextFileName = targetName
        return true
    }

    /// Moves existing `.txt` exports from `oldDirectory` to `newDirectory` (and
    /// generates `.txt` files for any completed items that hadn't been exported
    /// yet), updating each item's stored metadata.
    ///
    /// If `newDirectory` already contains a file at the target name, compares
    /// its SHA-256 hash against the source file: identical files are left
    /// untouched (not overwritten), while differing files are overwritten.
    static func migrateExports(
        items: [TranscriptionItem],
        from oldDirectory: URL,
        to newDirectory: URL
    ) -> MigrationResult {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: newDirectory, withIntermediateDirectories: true)
        } catch {
            return MigrationResult(
                migratedCount: 0,
                skippedCount: 0,
                failedCount: items.filter { $0.status == .completed }.count,
                firstError: error.localizedDescription
            )
        }

        var migrated = 0
        var skipped = 0
        var failed = 0
        var firstError: String?
        var usedTargetNames = Set<String>()

        for item in items where item.status == .completed {
            let baseName = sanitizeExportBaseName(item.fileName, fallbackID: item.id)
            let preferredBase: String
            if let oldName = item.exportedTextFileName, matchesBaseName(oldName, baseName: baseName) {
                preferredBase = (oldName as NSString).deletingPathExtension
            } else {
                preferredBase = baseName
            }

            // Avoid collisions between two distinct items in this migration batch,
            // while intentionally targeting an existing filename in `newDirectory`
            // so we can compare hashes and skip or overwrite it.
            var targetName = "\(preferredBase).txt"
            if usedTargetNames.contains(targetName) {
                var counter = 2
                while usedTargetNames.contains("\(preferredBase) (\(counter)).txt") {
                    counter += 1
                }
                targetName = "\(preferredBase) (\(counter)).txt"
            }
            usedTargetNames.insert(targetName)

            let destURL = newDirectory.appendingPathComponent(targetName)
            let oldURL: URL? = item.exportedTextFileName.map { oldDirectory.appendingPathComponent($0) }
            let hasOldFile = oldURL.map { fm.fileExists(atPath: $0.path) } ?? false

            do {
                let sourceData: Data
                if let oldURL, hasOldFile {
                    sourceData = try Data(contentsOf: oldURL)
                } else {
                    let text = SubtitleFormatter.plainText(segments: item.segments, fallbackText: item.fullText)
                    sourceData = Data(text.utf8)
                }

                if fm.fileExists(atPath: destURL.path) {
                    let existingData = try Data(contentsOf: destURL)
                    if SHA256.hash(data: sourceData) == SHA256.hash(data: existingData) {
                        if let oldURL, hasOldFile {
                            try? fm.removeItem(at: oldURL)
                        }
                        item.exportedTextFileName = targetName
                        saveMetadata(item)
                        skipped += 1
                        continue
                    }

                    // Hash differs: overwrite existing file atomically.
                    try sourceData.write(to: destURL, options: .atomic)
                    if let oldURL, hasOldFile {
                        try? fm.removeItem(at: oldURL)
                    }
                    item.exportedTextFileName = targetName
                    saveMetadata(item)
                    migrated += 1
                } else if let oldURL, hasOldFile {
                    try fm.moveItem(at: oldURL, to: destURL)
                    item.exportedTextFileName = targetName
                    saveMetadata(item)
                    migrated += 1
                } else {
                    try sourceData.write(to: destURL, options: .atomic)
                    item.exportedTextFileName = targetName
                    saveMetadata(item)
                    migrated += 1
                }
            } catch {
                failed += 1
                if firstError == nil { firstError = error.localizedDescription }
            }
        }

        return MigrationResult(
            migratedCount: migrated,
            skippedCount: skipped,
            failedCount: failed,
            firstError: firstError
        )
    }

    // MARK: - Load

    static func loadAll() -> [TranscriptionItem] {
        ensureDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: storeDirectory, includingPropertiesForKeys: nil
        ) else { return [] }

        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> TranscriptionItem? in
                guard let data = try? Data(contentsOf: url),
                      let stored = try? decoder.decode(StoredItem.self, from: data)
                else { return nil }

                let status: TranscriptionStatus
                switch stored.statusTag {
                case "completed": status = .completed
                case "failed":    status = .failed(stored.errorMessage ?? "Unknown error")
                default:          status = .pending
                }

                let item = TranscriptionItem(
                    id: stored.id,
                    fileName: stored.fileName,
                    fileURL: resolveRecordingURL(storedPath: stored.filePath),
                    dateAdded: stored.dateAdded,
                    status: status,
                    segments: stored.segments,
                    fullText: stored.fullText,
                    translatedSegments: stored.translatedSegments ?? [],
                    translationLanguage: stored.translationLanguage,
                    exportedTextFileName: stored.exportedTextFileName
                )
                item.diarizationSourceSegments = stored.diarizationSourceSegments
                return item
            }
            .sorted { $0.dateAdded > $1.dateAdded }
    }

    // MARK: - Delete

    /// Whether the audio file lives in the app's own Recordings folder, i.e. was
    /// recorded by WhisperASR rather than imported (drag-drop / file picker).
    static func isAppRecording(_ url: URL) -> Bool {
        url.standardizedFileURL.path
            .hasPrefix(recordingsDirectory.standardizedFileURL.path + "/")
    }

    static func delete(_ item: TranscriptionItem) {
        try? FileManager.default.removeItem(at: fileURL(for: item.id))
        // Only audio the app recorded is ours to dispose of — and it goes to the
        // Trash, not straight to deletion. Imported files are left untouched.
        if isAppRecording(item.fileURL) {
            try? FileManager.default.trashItem(at: item.fileURL, resultingItemURL: nil)
        }
    }
}
