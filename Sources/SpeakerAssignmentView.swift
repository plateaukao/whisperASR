import SwiftUI

// MARK: - Speaker Assignment Sheet

/// Names the speakers diarization found. Saving writes the names back onto the
/// transcript, files them in the voice library, and keeps a short clip of each
/// one — which is what lets the next recording recognize them automatically.
struct SpeakerAssignmentView: View {
    let item: TranscriptionItem

    @Environment(AudioPlayerManager.self) private var audioPlayer
    @Environment(\.dismiss) private var dismiss

    /// One editable line per speaker found in the transcript.
    private struct Row: Identifiable {
        /// `SpeakerStats.groupKey` — what ties this line back to its segments.
        let id: String
        var name: String
        var colorHex: String
        let speakingTime: Double
        let segmentCount: Int
        let previewStart: Double
        let previewEnd: Double
    }

    @State private var rows: [Row] = []
    @State private var previewingRowID: String?
    @State private var previewTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Identify Speakers")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Text("\(rows.count) speaker\(rows.count == 1 ? "" : "s") found. Name them and the app will remember their voices for next time.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach($rows) { $row in
                        rowView($row)
                    }
                }
                .padding(.vertical, 4)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { saveAssignments() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 460, height: 420)
        .onAppear {
            rows = makeRows()
            audioPlayer.load(url: item.fileURL)
        }
        .onDisappear {
            previewTask?.cancel()
            audioPlayer.pause()
        }
    }

    // MARK: - Rows

    private func rowView(_ row: Binding<Row>) -> some View {
        let current = row.wrappedValue
        return HStack(spacing: 10) {
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: NSColor(hexString: current.colorHex) ?? .systemGray) },
                set: { row.wrappedValue.colorHex = NSColor($0).hexString }
            ), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                TextField("Speaker name", text: row.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Text("\(SpeakerStats.formatDuration(current.speakingTime)) · \(current.segmentCount) segments")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                togglePreview(current)
            } label: {
                Image(systemName: previewingRowID == current.id ? "stop.fill" : "play.fill")
            }
            .help("Play a few seconds of this speaker")
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func makeRows() -> [Row] {
        SpeakerStats.compute(for: item.segments).map { stat in
            // Preview the speaker's most representative segment — the one closest
            // to a few seconds long, same rule the voice samples use.
            let candidate = item.segments
                .filter { SpeakerStats.groupKey(for: $0) == stat.id }
                .min {
                    abs((($0.end ?? $0.start) - $0.start) - 3)
                        < abs((($1.end ?? $1.start) - $1.start) - 3)
                }
            let start = candidate?.start ?? 0
            let end = candidate?.end ?? (start + 3)
            return Row(
                id: stat.id,
                name: stat.name,
                colorHex: stat.colorHex ?? SpeakerProfile.randomColorHex(),
                speakingTime: stat.speakingTime,
                segmentCount: stat.segmentCount,
                previewStart: start,
                previewEnd: min(end, start + 5)
            )
        }
    }

    // MARK: - Preview

    private func togglePreview(_ row: Row) {
        previewTask?.cancel()
        guard previewingRowID != row.id else {
            audioPlayer.pause()
            previewingRowID = nil
            return
        }

        audioPlayer.seek(to: row.previewStart)
        audioPlayer.play()
        previewingRowID = row.id

        // AVPlayer has no "play until": poll the position and stop at the end of
        // the segment, so the preview doesn't run on into the next speaker.
        previewTask = Task {
            while !Task.isCancelled, audioPlayer.currentTime < row.previewEnd {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard !Task.isCancelled else { return }
            audioPlayer.pause()
            if previewingRowID == row.id { previewingRowID = nil }
        }
    }

    // MARK: - Saving

    private func saveAssignments() {
        // A name the library already knows is the same person: reuse the profile
        // instead of creating a second one, so their samples keep accumulating.
        var profilesByRow: [String: SpeakerProfile] = [:]
        for row in rows {
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            var profile = SpeakerLibrary.speaker(named: name)
                ?? SpeakerProfile(name: name, colorHex: row.colorHex)
            profile.colorHex = row.colorHex
            profilesByRow[row.id] = SpeakerLibrary.upsertSpeaker(profile)
        }

        var segments = item.segments
        for index in segments.indices {
            guard let profile = profilesByRow[SpeakerStats.groupKey(for: segments[index])] else { continue }
            segments[index].speakerID = profile.id
            segments[index].speakerName = profile.name
            segments[index].speakerColor = profile.colorHex
        }
        item.segments = segments
        TranscriptionStore.save(item)

        for profile in profilesByRow.values {
            SpeakerLibrary.incrementRecordingCount(id: profile.id)
        }

        // Enrollment audio is cut in the background: it re-reads the recording,
        // and the user shouldn't wait on it to close the sheet.
        Task {
            await VoiceSampleExtractor.autoSaveVoiceSamples(
                audioURL: item.fileURL,
                segments: segments,
                sourceRecordingID: item.id
            )
        }
        dismiss()
    }
}
