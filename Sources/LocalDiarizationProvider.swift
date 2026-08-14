import FluidAudio
import Foundation

// MARK: - Local Provider

/// On-device diarization via FluidAudio (Core ML / ANE), the same dependency the
/// Nemotron ASR engine already uses — so it adds no new package.
///
/// Known voices are enrolled before the pass: their embedding is registered with
/// the diarizer, which then tracks the cluster under that speaker's id instead of
/// a fresh number. Clusters that come back unnamed are compared against the
/// library afterwards (`SpeakerEmbeddingMatcher`), which catches voices the
/// diarizer's own threshold was too strict about. Models download on first use
/// from Hugging Face, mirroring how the app downloads speech-recognition models.
struct LocalDiarizationProvider: DiarizationProvider {

    /// FluidAudio's pipeline is fixed at 16 kHz mono, which is what `AudioLoader`
    /// already produces for whisper.
    private static let sampleRate = 16_000

    var displayName: String { "On-device (FluidAudio)" }

    func diarize(audioURL: URL,
                 knownSpeakers: [KnownSpeakerSample],
                 progress: @escaping @Sendable (Double) -> Void) async throws -> SpeakerDiarizationResult {
        // First run downloads ~100–200 MB and compiles the Core ML models for the
        // ANE (minutes); afterwards the OS caches them and this returns in about
        // a second. The download owns the first 30% of the progress bar so that
        // first run doesn't look hung; when cached it just skips ahead.
        let models = try await DiarizerModels.downloadIfNeeded(progressHandler: { update in
            progress(update.fractionCompleted * 0.3)
        })
        progress(0.3)
        try Task.checkCancellation()

        let manager = DiarizerManager()
        manager.initialize(models: models)

        let enrollment = try await enroll(knownSpeakers, with: manager)
        try Task.checkCancellation()

        let samples = try await AudioLoader.loadSamples(url: audioURL)
        guard !samples.isEmpty else {
            throw DiarizationError.providerUnavailable("the audio file is empty or unreadable")
        }
        try Task.checkCancellation()

        let result = try manager.performCompleteDiarization(
            samples, sampleRate: Self.sampleRate,
            progressHandler: { fraction in
                progress(0.3 + fraction * 0.7)
            })
        let identities = resolveIdentities(in: result, manager: manager, enrollment: enrollment)

        let turns = result.segments.map { segment in
            let identity = identities[segment.speakerId]
            return SpeakerTurn(
                start: Double(segment.startTimeSeconds),
                end: Double(segment.endTimeSeconds),
                label: identity?.name ?? Self.fallbackLabel(for: segment.speakerId),
                speakerID: identity?.speakerID
            )
        }
        return SpeakerDiarizationResult(
            turns: turns,
            extractedEmbeddings: enrollment.extractedEmbeddings
        )
    }

    // MARK: - Enrollment

    /// Known voices prepared for one diarization pass.
    private struct Enrollment {
        /// Speaker ids the diarizer was seeded with, keyed by their cluster id
        /// (which is the profile UUID, since that is the id we enrolled under).
        var enrolledIDs: Set<String> = []
        var namesByID: [UUID: String] = [:]
        var references: [SpeakerEmbeddingMatcher.Reference] = []
        /// Embeddings extracted this pass, to cache back into the library.
        var extractedEmbeddings: [UUID: [Float]] = [:]
    }

    /// Turns each known voice sample into an embedding and registers it with the
    /// diarizer. Extraction is the expensive part, so a sample whose embedding the
    /// library already cached is reused as-is. A sample that fails to load is
    /// skipped rather than failing the whole pass — one stale file shouldn't cost
    /// the user their diarization.
    private func enroll(_ knownSpeakers: [KnownSpeakerSample],
                        with manager: DiarizerManager) async throws -> Enrollment {
        var enrollment = Enrollment()
        var speakers: [Speaker] = []

        for known in knownSpeakers {
            try Task.checkCancellation()

            let embedding: [Float]
            if let cached = known.embedding, !cached.isEmpty {
                embedding = cached
            } else {
                guard let audio = try? await AudioLoader.loadSamples(url: known.fileURL),
                      !audio.isEmpty,
                      let extracted = try? manager.extractSpeakerEmbedding(from: audio) else {
                    print("[Diarization] skipping unreadable voice sample for \(known.name)")
                    continue
                }
                embedding = extracted
                enrollment.extractedEmbeddings[known.sampleID] = extracted
            }

            // Enrolling under the profile's UUID means the diarizer hands the
            // cluster back with that same id, so recognition needs no lookup.
            speakers.append(Speaker(
                id: known.speakerID.uuidString,
                name: known.name,
                currentEmbedding: embedding,
                isPermanent: true
            ))
            enrollment.enrolledIDs.insert(known.speakerID.uuidString)
            enrollment.namesByID[known.speakerID] = known.name
            enrollment.references.append(
                SpeakerEmbeddingMatcher.Reference(speakerID: known.speakerID, embedding: embedding))
        }

        if !speakers.isEmpty {
            manager.initializeKnownSpeakers(speakers)
        }
        return enrollment
    }

    // MARK: - Identity resolution

    private struct ClusterIdentity {
        let speakerID: UUID
        let name: String
    }

    /// Maps clusters to library speakers. A cluster the diarizer tracked under an
    /// enrolled id is a direct hit; the remaining clusters and the remaining
    /// (unclaimed) known voices go through one one-to-one cosine assignment.
    private func resolveIdentities(in result: DiarizationResult,
                                   manager: DiarizerManager,
                                   enrollment: Enrollment) -> [String: ClusterIdentity] {
        var identities: [String: ClusterIdentity] = [:]
        var unmatched: [(id: String, embedding: [Float])] = []

        for segment in result.segments {
            let clusterID = segment.speakerId
            guard identities[clusterID] == nil,
                  !unmatched.contains(where: { $0.id == clusterID }) else { continue }

            if enrollment.enrolledIDs.contains(clusterID),
               let speakerID = UUID(uuidString: clusterID),
               let name = enrollment.namesByID[speakerID] {
                identities[clusterID] = ClusterIdentity(speakerID: speakerID, name: name)
            } else {
                // The cluster's running embedding is the better reference, but a
                // cluster the manager no longer lists falls back to this segment's.
                let embedding = manager.speakerManager.getAllSpeakers()[clusterID]?.currentEmbedding
                    ?? segment.embedding
                unmatched.append((id: clusterID, embedding: embedding))
            }
        }

        // Voices already claimed by a direct hit are out of the running — the
        // enrolled cluster IS that person, so another cluster can't be too.
        let claimed = Set(identities.values.map(\.speakerID))
        let available = enrollment.references.filter { !claimed.contains($0.speakerID) }
        for (clusterID, speakerID) in SpeakerEmbeddingMatcher.assign(clusters: unmatched,
                                                                     references: available) {
            guard let name = enrollment.namesByID[speakerID] else { continue }
            identities[clusterID] = ClusterIdentity(speakerID: speakerID, name: name)
        }
        return identities
    }

    /// FluidAudio names unknown clusters "1", "2", … — readable enough once
    /// prefixed, and stable across the pass so the UI can group by it.
    private static func fallbackLabel(for clusterID: String) -> String {
        Int(clusterID) != nil ? "Speaker \(clusterID)" : clusterID
    }
}
