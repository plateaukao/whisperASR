import SwiftUI

// MARK: - Speaker Stats

/// How much one speaker talked in a transcript.
struct SpeakerStat: Identifiable {
    /// Grouping key: the library speaker id, or the raw diarization label.
    let id: String
    let name: String
    let colorHex: String?
    let speakingTime: Double
    let segmentCount: Int
    let percentage: Int

    var color: Color {
        guard let colorHex, let nsColor = NSColor(hexString: colorHex) else { return .secondary }
        return Color(nsColor: nsColor)
    }
}

/// Aggregates segments per speaker for the summary header and the identify sheet,
/// so both group the transcript exactly the same way.
@MainActor
enum SpeakerStats {

    /// Stable grouping key for a segment. A speaker id that is no longer in the
    /// library (the speaker was deleted) falls back to the raw label — without
    /// that, every orphaned segment would group on its own and the transcript
    /// would appear to have as many speakers as it has lines.
    static func groupKey(for segment: TranscriptionSegment) -> String {
        if let id = segment.speakerID, SpeakerLibrary.speaker(id: id) != nil {
            return id.uuidString
        }
        return segment.diarizationLabel ?? segment.speakerName ?? "Unknown"
    }

    static func compute(for segments: [TranscriptionSegment]) -> [SpeakerStat] {
        var totals: [String: (name: String, colorHex: String?, time: Double, count: Int)] = [:]

        for segment in segments {
            let key = groupKey(for: segment)
            let name = segment.speakerDisplayName ?? "Unknown"
            var entry = totals[key] ?? (name: name, colorHex: segment.speakerColor, time: 0, count: 0)
            entry.time += max(0, (segment.end ?? segment.start) - segment.start)
            entry.count += 1
            // Earlier segments of a speaker can predate the naming pass; take the
            // first real name and color the group offers.
            if entry.name == "Unknown" { entry.name = name }
            if entry.colorHex == nil { entry.colorHex = segment.speakerColor }
            totals[key] = entry
        }

        let totalTime = totals.values.reduce(0) { $0 + $1.time }
        return totals
            .map { key, entry in
                SpeakerStat(
                    id: key,
                    name: entry.name,
                    colorHex: entry.colorHex,
                    speakingTime: entry.time,
                    segmentCount: entry.count,
                    percentage: totalTime > 0 ? Int((entry.time / totalTime * 100).rounded()) : 0
                )
            }
            .sorted { $0.speakingTime > $1.speakingTime }
    }

    /// Whether a transcript has been diarized at all.
    static func hasSpeakers(in segments: [TranscriptionSegment]) -> Bool {
        segments.contains { $0.speakerDisplayName != nil }
    }

    /// Color for an unnamed speaker, derived from the label so the same label
    /// always gets the same swatch — across segments, runs and app launches.
    static func stableColor(for label: String) -> String {
        var hash: UInt64 = 5381
        for scalar in label.unicodeScalars {
            hash = (hash &* 33) ^ UInt64(scalar.value)
        }
        return SpeakerProfile.palette[Int(hash % UInt64(SpeakerProfile.palette.count))]
    }

    /// "12:34" (or "1:02:03" past an hour), shared by the speaker views.
    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

// MARK: - NSColor hex helper

extension NSColor {
    /// Creates a color from a hex string like "#FF6B6B".
    convenience init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0,
            alpha: 1.0
        )
    }

    /// Hex string like "#FF6B6B" (alpha dropped).
    var hexString: String {
        guard let rgb = usingColorSpace(.deviceRGB) else { return "#888888" }
        return String(format: "#%02X%02X%02X",
                      Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()),
                      Int((rgb.blueComponent * 255).rounded()))
    }
}
