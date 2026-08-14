import Foundation

// MARK: - Diarization Service

/// Picks the diarization engine and reconciles its speaker turns with the
/// transcript's segments.
enum DiarizationService {

    /// Settings key, exposed so `SettingsView` and the service agree on it.
    static let useRemoteKey = "diarizationUseRemote"

    /// The engine the user selected. On-device is the default: it needs no key,
    /// no upload, and keeps the app usable entirely offline.
    static func provider() -> DiarizationProvider {
        guard UserDefaults.standard.bool(forKey: useRemoteKey) else {
            return LocalDiarizationProvider()
        }
        return OpenAIDiarizationProvider(
            apiKey: UserDefaults.standard.string(forKey: "translationAPIKey") ?? "")
    }

    // MARK: - Reconciliation with segments

    /// Labels each transcription segment with the speaker who talked through most
    /// of it. Whisper's segments and the diarizer's turns are cut on different
    /// boundaries, so the overlap has to be measured rather than matched.
    ///
    /// A turn carrying a `speakerID` was recognized as a known voice, and takes
    /// the library's name and color. Everything else keeps the engine's label with
    /// a color derived from it, so unnamed speakers still read consistently until
    /// the user names them. A segment no turn overlaps (silence, music) has its
    /// speaker fields cleared — this pass replaces the previous one wholesale, so
    /// a re-run can't leave stale labels behind.
    @MainActor
    static func assignSpeakers(to segments: [TranscriptionSegment],
                               turns: [SpeakerTurn]) -> [TranscriptionSegment] {
        segments.map { segment in
            var updated = segment
            guard let end = segment.end,
                  let turn = bestTurn(for: segment.start, end: end, turns: turns) else {
                updated.diarizationLabel = nil
                updated.speakerID = nil
                updated.speakerName = nil
                updated.speakerColor = nil
                return updated
            }

            updated.diarizationLabel = turn.label
            if let speakerID = turn.speakerID, let profile = SpeakerLibrary.speaker(id: speakerID) {
                updated.speakerID = profile.id
                updated.speakerName = profile.name
                updated.speakerColor = profile.colorHex
            } else {
                updated.speakerID = nil
                updated.speakerName = turn.label
                updated.speakerColor = SpeakerStats.stableColor(for: turn.label)
            }
            return updated
        }
    }

    /// The turn overlapping `start..<end` the longest, or nil when none does
    /// (silence and music fall outside every turn).
    static func bestTurn(for start: Double, end: Double, turns: [SpeakerTurn]) -> SpeakerTurn? {
        var best: SpeakerTurn?
        var bestOverlap = 0.0
        for turn in turns {
            let overlap = min(end, turn.end) - max(start, turn.start)
            if overlap > bestOverlap {
                bestOverlap = overlap
                best = turn
            }
        }
        return best
    }
}
