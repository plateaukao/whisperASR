import Foundation

/// A bounded, timestamped 48 kHz timeline. Owned by the recorder's serial audio queue.
/// Missing input is silence; late input is trimmed instead of shifting subsequent speech.
struct RecordingAudioMixer {
    static let sampleRate = 48_000
    static let blockSize = 960
    private static let capacity = sampleRate * 5

    enum Source { case system, microphone }

    private struct Segment {
        let start: Int
        let samples: [Float]
        var end: Int { start + samples.count }
    }

    private var system: [Segment] = []
    private var microphone: [Segment] = []
    private var gain: Float = 1
    private(set) var nextFrame = 0

    mutating func append(_ samples: [Float], at time: TimeInterval, source: Source) {
        guard time.isFinite, !samples.isEmpty else { return }
        let position = (time * Double(Self.sampleRate)).rounded()
        guard position > Double(nextFrame - Self.capacity),
              position < Double(nextFrame + Self.capacity) else { return }
        let start = Int(position)
        let lower = max(start, nextFrame)
        let upper = min(start + samples.count, nextFrame + Self.capacity)
        guard upper > lower else { return }
        let segment = Segment(start: lower, samples: Array(samples[(lower - start)..<(upper - start)]))
        switch source {
        case .system: system.append(segment)
        case .microphone: microphone.append(segment)
        }
    }

    mutating func render(frameCount: Int) -> [Float] {
        precondition(frameCount > 0 && frameCount <= Self.blockSize)
        let end = nextFrame + frameCount
        var result = [Float](repeating: 0, count: frameCount)
        // Copy each source onto the same timeline before summing, so overlapping
        // callbacks from one device do not count that device twice.
        for track in [system, microphone] {
            var input = [Float](repeating: 0, count: frameCount)
            for segment in track {
                let lower = max(nextFrame, segment.start)
                let upper = min(end, segment.end)
                guard upper > lower else { continue }
                for frame in lower..<upper {
                    let sample = segment.samples[frame - segment.start]
                    input[frame - nextFrame] = sample.isFinite ? sample : 0
                }
            }
            for i in result.indices { result[i] += input[i] }
        }
        // Block lookahead prevents clipping without flattening the waveform.
        // Recover gain over roughly half a second to avoid abrupt level jumps.
        let peak = result.reduce(Float(0)) { max($0, abs($1)) }
        let requiredGain: Float = peak > 0.98 ? 0.98 / peak : 1
        gain = min(requiredGain, gain + Float(frameCount) / Float(Self.sampleRate / 2))
        for i in result.indices { result[i] *= gain }
        nextFrame = end
        system.removeAll { $0.end <= end }
        microphone.removeAll { $0.end <= end }
        return result
    }
}
