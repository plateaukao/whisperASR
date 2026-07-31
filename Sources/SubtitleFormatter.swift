import Foundation

// MARK: - Subtitle Format

/// Subtitle file formats the app can render from transcription segments.
/// Shared by the OpenAI-compatible API (`response_format`) and the UI's
/// Export menu.
enum SubtitleFormat: String, CaseIterable, Identifiable {
    case srt
    case vtt
    case sub

    var id: String { rawValue }

    var fileExtension: String { rawValue }

    var displayName: String {
        switch self {
        case .srt: return "SubRip (.srt)"
        case .vtt: return "WebVTT (.vtt)"
        case .sub: return "SubViewer (.sub)"
        }
    }
}

// MARK: - Subtitle Formatter

enum SubtitleFormatter {
    static func make(_ format: SubtitleFormat, segments: [TranscriptionSegment], title: String = "") -> String {
        switch format {
        case .srt: return makeSRT(segments)
        case .vtt: return makeVTT(segments)
        case .sub: return makeSUB(segments, title: title)
        }
    }

    static func makeSRT(_ segments: [TranscriptionSegment]) -> String {
        var out = ""
        for (i, seg) in segments.enumerated() {
            let line = speakerLine(seg)
            out += "\(i + 1)\n"
            out += "\(srtTime(seg.start)) --> \(srtTime(seg.end ?? seg.start))\n"
            out += "\(line)\n\n"
        }
        return out
    }

    static func makeVTT(_ segments: [TranscriptionSegment]) -> String {
        var out = "WEBVTT\n\n"
        for seg in segments {
            let line = speakerLine(seg)
            out += "\(vttTime(seg.start)) --> \(vttTime(seg.end ?? seg.start))\n"
            out += "\(line)\n\n"
        }
        return out
    }

    /// SubViewer 2.0: time-based cues (`HH:MM:SS.cc`, centiseconds) — the
    /// MicroDVD `.sub` variant is frame-based and needs a video frame rate,
    /// which audio transcripts don't have.
    static func makeSUB(_ segments: [TranscriptionSegment], title: String = "") -> String {
        var out = "[INFORMATION]\n[TITLE]\(title)\n[END INFORMATION]\n\n"
        for seg in segments {
            let line = speakerLine(seg)
            out += "\(subTime(seg.start)),\(subTime(seg.end ?? seg.start))\n"
            out += "\(line)\n\n"
        }
        return out
    }

    private static func clockParts(_ t: Double) -> (h: Int, m: Int, s: Int, ms: Int) {
        let total = Int((max(0, t) * 1000).rounded())
        return (total / 3_600_000, (total % 3_600_000) / 60_000, (total % 60_000) / 1000, total % 1000)
    }

    /// The segment's text, prefixed with the speaker when the transcript has been
    /// diarized. Subtitles are the one export where "who said it" has to ride
    /// along with the line itself, since there is no column to put it in.
    static func speakerLine(_ seg: TranscriptionSegment) -> String {
        let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let speaker = seg.speakerDisplayName, !speaker.isEmpty else {
            return text
        }
        return "\(speaker): \(text)"
    }

    static func srtTime(_ t: Double) -> String {
        let p = clockParts(t)
        return String(format: "%02d:%02d:%02d,%03d", p.h, p.m, p.s, p.ms)
    }

    static func vttTime(_ t: Double) -> String {
        let p = clockParts(t)
        return String(format: "%02d:%02d:%02d.%03d", p.h, p.m, p.s, p.ms)
    }

    static func subTime(_ t: Double) -> String {
        let p = clockParts(t)
        return String(format: "%02d:%02d:%02d.%02d", p.h, p.m, p.s, p.ms / 10)
    }
}
