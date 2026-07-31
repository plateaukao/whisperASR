import Accelerate
import Foundation

// MARK: - Speaker Embedding Matcher

/// Matches diarization clusters to known voices by cosine similarity of their
/// speaker embeddings (256-dim, L2-normalized by the embedding model).
///
/// The diarizer already recognizes voices it was enrolled with, but it only does
/// so when a cluster is close enough for *its* threshold. This is the second
/// pass: clusters that came back unnamed are compared against the whole library
/// so a voice recorded in an earlier session is still identified.
enum SpeakerEmbeddingMatcher {

    /// Minimum cosine similarity to accept a match. Deliberately strict —
    /// stricter than the diarizer's own acceptance (FluidAudio compares cosine
    /// *distance* against ~0.84, i.e. similarity above ~0.16) — because this pass
    /// only names clusters the diarizer left anonymous, and a false name is worse
    /// than no name.
    static let minSimilarity: Float = 0.65

    /// A known voice to match against.
    struct Reference: Equatable {
        let speakerID: UUID
        let embedding: [Float]
    }

    /// Resolves clusters to known speakers one-to-one: each cluster gets at most
    /// one speaker and each speaker at most one cluster (two clusters must be two
    /// different people — letting both take the same name would merge them).
    /// Pairs are granted greedily by descending similarity, so when two clusters
    /// both resemble one voice, the closer cluster wins and the other stays
    /// anonymous. Returns cluster id → matched speaker.
    static func assign(clusters: [(id: String, embedding: [Float])],
                       references: [Reference]) -> [String: UUID] {
        var scored: [(clusterID: String, speakerID: UUID, similarity: Float)] = []
        for cluster in clusters {
            for reference in references {
                let similarity = cosineSimilarity(cluster.embedding, reference.embedding)
                guard similarity >= minSimilarity else { continue }
                scored.append((cluster.id, reference.speakerID, similarity))
            }
        }

        var assigned: [String: UUID] = [:]
        var takenSpeakers: Set<UUID> = []
        for match in scored.sorted(by: { $0.similarity > $1.similarity }) {
            guard assigned[match.clusterID] == nil, !takenSpeakers.contains(match.speakerID) else {
                continue
            }
            assigned[match.clusterID] = match.speakerID
            takenSpeakers.insert(match.speakerID)
        }
        return assigned
    }

    /// Cosine similarity between two vectors; 0 for empty or mismatched inputs.
    /// Embeddings arrive L2-normalized, but the norms are still divided out so a
    /// non-normalized vector can't inflate the score.
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))
        let denominator = (normA * normB).squareRoot()
        return denominator > 0 ? dot / denominator : 0
    }
}
