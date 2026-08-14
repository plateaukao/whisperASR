import Foundation

// MARK: - Model

/// A known speaker in the global voice library.
struct SpeakerProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var colorHex: String
    let createdAt: Date
    var updatedAt: Date
    /// How many recordings this speaker has been identified in.
    var recordingCount: Int = 0

    init(id: UUID = UUID(), name: String, colorHex: String = Self.randomColorHex(),
         createdAt: Date = Date(), recordingCount: Int = 0) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.recordingCount = recordingCount
    }

    /// Fixed palette so speakers get stable, distinguishable colors.
    static let palette: [String] = [
        "#FF6B6B", "#4ECDC4", "#45B7D1", "#96CEB4",
        "#FFEAA7", "#DDA0DD", "#98D8C8", "#F7DC6F",
        "#BB8FCE", "#85C1E9", "#F1948A", "#82E0AA",
    ]

    static func randomColorHex() -> String {
        palette.randomElement() ?? "#FF6B6B"
    }
}

/// A recorded voice sample used to recognize a speaker in later transcriptions.
struct VoiceSample: Codable, Identifiable, Equatable {
    let id: UUID
    let speakerID: UUID
    /// Audio file (WAV mono 16 kHz, 2–5 s) inside the library's Samples folder.
    let fileURL: URL
    let duration: Double
    let createdAt: Date
    /// Transcription this sample was extracted from, for provenance.
    let sourceRecordingID: UUID?
    /// 256-dim speaker embedding, cached the first time a diarization pass
    /// extracts it so later passes don't redo the Core ML work.
    var embedding: [Float]?
}

// MARK: - Library

/// Global library of known voices, persisted as JSON in Application Support
/// alongside `TranscriptionStore`. Main-actor bound: the UI reads it directly and
/// every mutation is small (index writes only, audio lives in separate files).
@MainActor
enum SpeakerLibrary {

    // MARK: - Directories

    private static var libraryDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("WhisperASR", isDirectory: true)
            .appendingPathComponent("Speakers", isDirectory: true)
    }

    /// Folder holding a speaker's WAV samples. Single source of truth for the
    /// layout — `VoiceSampleExtractor` writes here too.
    static func samplesDirectory(for speakerID: UUID) -> URL {
        libraryDirectory
            .appendingPathComponent("Samples", isDirectory: true)
            .appendingPathComponent(speakerID.uuidString, isDirectory: true)
    }

    private static var indexFile: URL {
        libraryDirectory.appendingPathComponent("library.json")
    }

    // MARK: - Codable DTO

    private struct LibraryIndex: Codable {
        var speakers: [SpeakerProfile] = []
        var samples: [VoiceSample] = []
    }

    // MARK: - Persistence

    private static var cache: LibraryIndex = {
        guard let data = try? Data(contentsOf: indexFile),
              let index = try? JSONDecoder().decode(LibraryIndex.self, from: data) else {
            return LibraryIndex()
        }
        return index
    }()

    private static func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(cache) else { return }
        try? FileManager.default.createDirectory(
            at: libraryDirectory, withIntermediateDirectories: true)
        try? data.write(to: indexFile, options: .atomic)
    }

    // MARK: - Speakers

    static var speakers: [SpeakerProfile] {
        cache.speakers.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func speaker(id: UUID) -> SpeakerProfile? {
        cache.speakers.first { $0.id == id }
    }

    static func speaker(named name: String) -> SpeakerProfile? {
        cache.speakers.first { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
    }

    @discardableResult
    static func upsertSpeaker(_ profile: SpeakerProfile) -> SpeakerProfile {
        var updated = profile
        if let idx = cache.speakers.firstIndex(where: { $0.id == profile.id }) {
            updated.updatedAt = Date()
            cache.speakers[idx] = updated
        } else {
            cache.speakers.append(updated)
        }
        persist()
        return updated
    }

    static func deleteSpeaker(id: UUID) {
        cache.speakers.removeAll { $0.id == id }
        cache.samples.removeAll { $0.speakerID == id }
        try? FileManager.default.removeItem(at: samplesDirectory(for: id))
        persist()
    }

    static func incrementRecordingCount(id: UUID) {
        guard var profile = speaker(id: id) else { return }
        profile.recordingCount += 1
        upsertSpeaker(profile)
    }

    // MARK: - Voice samples

    static func samples(for speakerID: UUID) -> [VoiceSample] {
        cache.samples
            .filter { $0.speakerID == speakerID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    static func addVoiceSample(speakerID: UUID, wavFile: URL, duration: Double,
                               sourceRecordingID: UUID?) -> VoiceSample {
        let sample = VoiceSample(
            id: UUID(), speakerID: speakerID, fileURL: wavFile, duration: duration,
            createdAt: Date(), sourceRecordingID: sourceRecordingID, embedding: nil
        )
        cache.samples.append(sample)
        persist()
        return sample
    }

    static func deleteVoiceSample(id: UUID) {
        guard let sample = cache.samples.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: sample.fileURL)
        cache.samples.removeAll { $0.id == id }
        persist()
    }

    /// Caches embeddings extracted during a diarization pass, keyed by sample id.
    static func cacheEmbeddings(_ embeddings: [UUID: [Float]]) {
        guard !embeddings.isEmpty else { return }
        var changed = false
        for (sampleID, embedding) in embeddings {
            guard let idx = cache.samples.firstIndex(where: { $0.id == sampleID }),
                  cache.samples[idx].embedding != embedding else { continue }
            cache.samples[idx].embedding = embedding
            changed = true
        }
        if changed { persist() }
    }

    /// The voices to hand a diarization provider. One sample per speaker (the
    /// most recent), since providers only need a single reference per voice.
    static func knownSpeakerSamples(for speakerIDs: [UUID]? = nil) -> [KnownSpeakerSample] {
        let profiles = speakerIDs.map { ids in ids.compactMap { speaker(id: $0) } } ?? speakers
        return profiles.compactMap { profile in
            guard let sample = samples(for: profile.id).first,
                  FileManager.default.fileExists(atPath: sample.fileURL.path) else { return nil }
            return KnownSpeakerSample(
                speakerID: profile.id,
                sampleID: sample.id,
                name: profile.name,
                fileURL: sample.fileURL,
                embedding: sample.embedding
            )
        }
    }
}
