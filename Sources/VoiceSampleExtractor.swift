import Foundation

// MARK: - Voice Sample Extractor

/// Cuts a short clip of each named speaker out of a recording and files it in the
/// voice library. This is what makes recognition improve on its own: naming the
/// speakers once leaves behind the reference audio that later diarizations enroll.
@MainActor
enum VoiceSampleExtractor {

    /// Enrollment clips are 2–5 s: shorter carries too little voice to embed,
    /// longer tends to swallow another speaker or silence. 3 s is the sweet spot.
    private static let idealDuration: Double = 3.0
    private static let minDuration: Double = 2.0
    private static let maxClipDuration: Double = 5.0
    /// Samples kept per speaker; the oldest are pruned beyond this.
    private static let maxSamplesPerSpeaker = 3

    /// Saves one clip per identified speaker in `segments`. Segments without a
    /// library speaker id are skipped — an unnamed speaker has nothing to enroll
    /// against. Failures are logged and skipped rather than thrown: this runs
    /// after the transcript is already saved, and a missing sample only costs
    /// recognition quality on the next recording.
    static func autoSaveVoiceSamples(audioURL: URL,
                                     segments: [TranscriptionSegment],
                                     sourceRecordingID: UUID?) async {
        var bySpeaker: [UUID: [TranscriptionSegment]] = [:]
        for segment in segments {
            guard let speakerID = segment.speakerID else { continue }
            bySpeaker[speakerID, default: []].append(segment)
        }
        guard !bySpeaker.isEmpty else { return }

        let audio: [Float]
        do {
            audio = try await AudioLoader.loadSamples(url: audioURL)
        } catch {
            print("[VoiceSample] couldn't load \(audioURL.lastPathComponent): \(error)")
            return
        }

        for (speakerID, speakerSegments) in bySpeaker {
            guard let profile = SpeakerLibrary.speaker(id: speakerID),
                  let segment = bestSegment(among: speakerSegments) else { continue }

            let start = segment.start
            let end = min(segment.end ?? (start + idealDuration), start + maxClipDuration)
            let wav = makeWAV(samples: audio, start: start, end: end)
            guard !wav.isEmpty else { continue }

            let directory = SpeakerLibrary.samplesDirectory(for: profile.id)
            let fileURL = directory.appendingPathComponent("\(UUID().uuidString).wav")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try wav.write(to: fileURL, options: .atomic)
            } catch {
                print("[VoiceSample] couldn't save a sample for \(profile.name): \(error)")
                continue
            }
            SpeakerLibrary.addVoiceSample(speakerID: profile.id, wavFile: fileURL,
                                          duration: end - start,
                                          sourceRecordingID: sourceRecordingID)
            pruneOldSamples(speakerID: profile.id)
        }
    }

    /// The segment closest to `idealDuration`, ignoring ones too short to carry
    /// a voice. Longer segments stay eligible — the clip is capped at
    /// `maxClipDuration` when cut, so only their opening seconds are used.
    private static func bestSegment(among segments: [TranscriptionSegment]) -> TranscriptionSegment? {
        segments
            .filter { ($0.end ?? $0.start) - $0.start >= minDuration }
            .min {
                abs((($0.end ?? $0.start) - $0.start) - idealDuration)
                    < abs((($1.end ?? $1.start) - $1.start) - idealDuration)
            }
    }

    /// Keeps only the newest samples; `samples(for:)` returns newest first.
    private static func pruneOldSamples(speakerID: UUID) {
        for sample in SpeakerLibrary.samples(for: speakerID).dropFirst(maxSamplesPerSpeaker) {
            SpeakerLibrary.deleteVoiceSample(id: sample.id)
        }
    }

    // MARK: - WAV encoding

    /// Encodes `samples[start..<end]` as 16-bit PCM mono WAV — the format both
    /// diarization engines accept as a known-speaker reference. Input is the
    /// 16 kHz mono Float32 PCM `AudioLoader` produces.
    static func makeWAV(samples: [Float], start: Double, end: Double) -> Data {
        let sampleRate = 16_000
        let startIndex = max(0, Int(start * Double(sampleRate)))
        let endIndex = min(Int(end * Double(sampleRate)), samples.count)
        guard endIndex > startIndex else { return Data() }

        var pcm = Data(capacity: (endIndex - startIndex) * 2)
        for sample in samples[startIndex..<endIndex] {
            let clamped = max(-1.0, min(1.0, sample))
            pcm.append(contentsOf: Int16(clamped * 32767).littleEndianBytes)
        }

        var wav = Data()
        wav.append(contentsOf: Array("RIFF".utf8))
        wav.append(contentsOf: UInt32(36 + pcm.count).littleEndianBytes)
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8))
        wav.append(contentsOf: UInt32(16).littleEndianBytes)            // fmt chunk size
        wav.append(contentsOf: UInt16(1).littleEndianBytes)             // PCM
        wav.append(contentsOf: UInt16(1).littleEndianBytes)             // mono
        wav.append(contentsOf: UInt32(sampleRate).littleEndianBytes)
        wav.append(contentsOf: UInt32(sampleRate * 2).littleEndianBytes)  // byte rate
        wav.append(contentsOf: UInt16(2).littleEndianBytes)             // block align
        wav.append(contentsOf: UInt16(16).littleEndianBytes)            // bits per sample
        wav.append(contentsOf: Array("data".utf8))
        wav.append(contentsOf: UInt32(pcm.count).littleEndianBytes)
        wav.append(pcm)
        return wav
    }
}

private extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: littleEndian) { Array($0) }
    }
}
