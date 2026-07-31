import Foundation

// MARK: - Model

/// A single speaker turn produced by a diarization engine.
struct SpeakerTurn: Equatable {
    let start: Double
    let end: Double
    /// Label to show when the speaker is not in the library (e.g. "Speaker 1").
    let label: String
    /// `SpeakerProfile.id` when the engine recognized a known voice, else nil.
    let speakerID: UUID?
}

/// Result of a diarization pass over one audio file.
struct SpeakerDiarizationResult: Equatable {
    let turns: [SpeakerTurn]
    /// Embeddings extracted from known-speaker samples during this pass, keyed by
    /// `VoiceSample.id`. Cached back into the library so the next pass skips the
    /// (expensive) extraction.
    var extractedEmbeddings: [UUID: [Float]] = [:]
}

// MARK: - Errors

enum DiarizationError: LocalizedError {
    case noAPIKey
    case fileTooLarge(bytes: Int, limit: Int)
    case providerUnavailable(String)
    case api(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "Add an OpenAI API key in Settings to use remote diarization."
        case .fileTooLarge(let bytes, let limit):
            return "Audio is too large for remote diarization: \(bytes / 1_048_576) MB (limit \(limit / 1_048_576) MB). Switch to the local engine in Settings."
        case .providerUnavailable(let msg):
            return "Diarization provider unavailable: \(msg)"
        case .api(let status, let msg):
            return "Diarization API error (\(status)): \(msg)"
        }
    }
}

// MARK: - Provider

/// Abstraction over a speaker diarization engine. Providers either run on-device
/// (FluidAudio / Core ML) or call a remote API (OpenAI gpt-4o-transcribe-diarize).
///
/// Implementations honour task cancellation: they call `Task.checkCancellation()`
/// at their suspension points rather than taking a cancellation callback.
protocol DiarizationProvider: Sendable {
    var displayName: String { get }

    /// Diarizes an audio file and returns speaker turns.
    /// - Parameters:
    ///   - audioURL: local audio file to analyze.
    ///   - knownSpeakers: voice samples used to recognize speakers by name.
    ///   - progress: overall progress in 0...1, including any first-run model
    ///     download. Called from an unspecified thread, like the transcription
    ///     progress callback. Providers with no meaningful granularity (one
    ///     remote round-trip) may never call it.
    func diarize(audioURL: URL,
                 knownSpeakers: [KnownSpeakerSample],
                 progress: @escaping @Sendable (Double) -> Void) async throws -> SpeakerDiarizationResult
}

/// A known voice handed to a provider so it can recognize that speaker by name.
struct KnownSpeakerSample: Sendable, Equatable {
    /// `SpeakerProfile.id` this sample belongs to.
    let speakerID: UUID
    /// `VoiceSample.id`, used as the key when caching the extracted embedding.
    let sampleID: UUID
    let name: String
    /// Local audio file (WAV mono 16 kHz, 2–5 s).
    let fileURL: URL
    /// Previously extracted embedding, when the library already cached one.
    let embedding: [Float]?
}
