import SwiftUI

// MARK: - Speaker Summary

/// Header above the transcript showing who spoke and for how long, plus the entry
/// points to run diarization and to name the speakers it found.
struct SpeakerSummaryView: View {
    let item: TranscriptionItem

    @Environment(AppState.self) private var appState
    @State private var showAssignment = false
    @State private var showParticipants = false
    @State private var isExpanded = true

    private var stats: [SpeakerStat] {
        SpeakerStats.compute(for: item.segments)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let error = item.diarizationError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }
            if isExpanded {
                if stats.isEmpty {
                    Text("No speakers identified yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // Capped and scrollable: a long meeting can turn up a dozen
                    // speakers, and the transcript below must stay visible.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(stats) { stat in
                                statRow(stat)
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .sheet(isPresented: $showAssignment) {
            SpeakerAssignmentView(item: item)
        }
        .sheet(isPresented: $showParticipants) {
            PreDiarizationView { knownSpeakerIDs in
                appState.diarizeItem(item, knownSpeakerIDs: knownSpeakerIDs)
            }
        }
    }

    private var header: some View {
        HStack {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Label("Speakers", systemImage: "person.2")
                    .font(.headline)
            }
            .buttonStyle(.plain)

            Spacer()

            if item.isDiarizing {
                // Progress covers the first-run model download too; a remote pass
                // reports nothing and keeps the indeterminate spinner.
                if item.diarizationProgress > 0 {
                    ProgressView(value: item.diarizationProgress)
                        .controlSize(.small)
                        .frame(width: 60)
                        .help("Identifying speakers…")
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .help("Identifying speakers…")
                }
            } else if SpeakerStats.hasSpeakers(in: item.segments) {
                // Re-running after naming speakers is the payoff of enrollment:
                // the pass now recognizes the voices that were just filed.
                Button {
                    startDiarization()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .controlSize(.small)
                .help("Diarize again with the current voice library")
                Button("Identify…", systemImage: "person.text.rectangle") {
                    showAssignment = true
                }
                .controlSize(.small)
            } else {
                Button("Diarize", systemImage: "person.wave.2") {
                    startDiarization()
                }
                .controlSize(.small)
            }
        }
    }

    /// Naming the participants up front lets the engine recognize them by voice;
    /// with an empty library there is nothing to pick, so skip straight to the run.
    private func startDiarization() {
        if SpeakerLibrary.speakers.isEmpty {
            appState.diarizeItem(item)
        } else {
            showParticipants = true
        }
    }

    private func statRow(_ stat: SpeakerStat) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(stat.color)
                .frame(width: 10, height: 10)
            Text(stat.name)
                .lineLimit(1)
            Spacer()
            Text(SpeakerStats.formatDuration(stat.speakingTime))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("\(stat.percentage)%")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }
}
