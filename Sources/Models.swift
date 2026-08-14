import Foundation
import Observation
import SwiftUI

// MARK: - Transcript Font Size

enum TranscriptFontSize: String, CaseIterable {
    case small, normal, large

    var label: String {
        switch self {
        case .small: return "Small"
        case .normal: return "Normal"
        case .large: return "Large"
        }
    }

    var bodyFont: Font {
        switch self {
        case .small: return .caption
        case .normal: return .body
        case .large: return .title3
        }
    }

    var translationFont: Font {
        switch self {
        case .small: return .caption2
        case .normal: return .callout
        case .large: return .body
        }
    }

    var timestampFont: Font {
        switch self {
        case .small: return .system(.caption2, design: .monospaced)
        case .normal: return .system(.caption, design: .monospaced)
        case .large: return .system(.footnote, design: .monospaced)
        }
    }
}

// MARK: - Transcription Segment

struct TranscriptionSegment: Codable, Equatable {
    let start: Double
    let end: Double?
    let text: String

    // Speaker diarization. All optional, so transcripts saved before the feature
    // existed still decode, and a transcript that was never diarized stays as it
    // was.
    /// The engine's own label for this speaker (e.g. "Speaker 1").
    var diarizationLabel: String?
    /// `SpeakerProfile.id`, set once the speaker is known to the voice library.
    var speakerID: UUID?
    /// The library's name for this speaker, once the user has named them.
    var speakerName: String?
    /// Hex color used for this speaker's dot in the transcript.
    var speakerColor: String?

    /// Name to show for this segment's speaker — the library's when known, else
    /// the engine's label; nil when the transcript hasn't been diarized. Single
    /// source of that precedence for the transcript view, exports and stats.
    var speakerDisplayName: String? {
        speakerName ?? diarizationLabel
    }
}

// MARK: - Transcription Result

struct TranscriptionResult: Codable {
    let text: String
    let segments: [TranscriptionSegment]
    /// Whisper's auto-detected language code (e.g. "en", "zh"). Populated for
    /// file transcription; used by the OpenAI-compatible API's verbose_json.
    var detectedLanguage: String? = nil
}

// MARK: - Status

enum TranscriptionStatus: Equatable {
    case pending
    case transcribing
    case completed
    case failed(String)
}

// MARK: - Errors

enum TranscriptionError: LocalizedError {
    case processFailed(String)
    case modelNotFound(String)

    var errorDescription: String? {
        switch self {
        case .processFailed(let msg): return "Transcription failed: \(msg)"
        case .modelNotFound(let msg): return msg
        }
    }
}

// MARK: - Transcription Item

@Observable
class TranscriptionItem: Identifiable {
    let id: UUID
    var fileName: String
    var fileURL: URL
    var status: TranscriptionStatus = .pending
    var segments: [TranscriptionSegment] = []
    var fullText: String = ""
    var progress: Double = 0
    var transcriptionStartTime: Date?
    var translatedSegments: [String] = []
    var translationLanguage: String?
    var isTranslating: Bool = false
    /// True while a diarization pass is running for this item.
    var isDiarizing: Bool = false
    /// Diarization progress (0...1) — covers the first-run model download too,
    /// which can dwarf the pass itself (~100–200 MB plus ANE compilation).
    var diarizationProgress: Double = 0
    /// Why the last diarization pass failed, shown above the transcript.
    var diarizationError: String?
    let dateAdded: Date

    init(fileURL: URL) {
        self.id = UUID()
        self.fileName = fileURL.lastPathComponent
        self.fileURL = fileURL
        self.dateAdded = Date()
    }

    /// Restore from persisted data
    init(id: UUID, fileName: String, fileURL: URL, dateAdded: Date,
         status: TranscriptionStatus, segments: [TranscriptionSegment], fullText: String,
         translatedSegments: [String] = [], translationLanguage: String? = nil) {
        self.id = id
        self.fileName = fileName
        self.fileURL = fileURL
        self.dateAdded = dateAdded
        self.status = status
        self.segments = segments
        self.fullText = fullText
        self.translatedSegments = translatedSegments
        self.translationLanguage = translationLanguage
    }
}
