import SwiftUI

// MARK: - Participants Sheet

/// Asks which known speakers are in this recording before diarizing. The engine
/// only enrolls the voices it is given, so narrowing the list to the people who
/// are actually present makes recognition both faster and less prone to matching
/// the wrong person from a large library.
struct PreDiarizationView: View {
    /// Called with the speakers to enroll. Skip passes nil ("not saying" — enroll
    /// the whole library); Start passes the exact selection, where empty means
    /// "none of these people are present" and nobody is enrolled.
    let onStart: ([UUID]?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<UUID> = []

    private var knownSpeakers: [SpeakerProfile] { SpeakerLibrary.speakers }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Who's in this recording?")
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

            Text("Selecting the people you recognize helps the app label them by name. You can skip this and name them afterwards.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(knownSpeakers) { speaker in
                        Toggle(isOn: selection(for: speaker.id)) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color(nsColor: NSColor(hexString: speaker.colorHex) ?? .systemGray))
                                    .frame(width: 12, height: 12)
                                Text(speaker.name)
                                if speaker.recordingCount > 0 {
                                    Text("· \(speaker.recordingCount) recording\(speaker.recordingCount == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(.vertical, 4)
            }

            HStack {
                Spacer()
                Button("Skip") {
                    onStart(nil)
                    dismiss()
                }
                Button("Start") {
                    onStart(Array(selectedIDs))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 380, height: 360)
    }

    private func selection(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(id) },
            set: { isOn in
                if isOn {
                    selectedIDs.insert(id)
                } else {
                    selectedIDs.remove(id)
                }
            }
        )
    }
}
