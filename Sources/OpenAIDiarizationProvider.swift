import Foundation

// MARK: - OpenAI Provider

/// Remote diarization via OpenAI's `gpt-4o-transcribe-diarize`. Slower and not
/// local, but more accurate on crowded or noisy conversations, so it stays as an
/// opt-in alternative to the on-device engine.
///
/// The model transcribes and diarizes in one call; only the speaker turns are
/// used here, since the transcript already exists by the time diarization runs.
/// It reuses the OpenAI API credentials configured in Settings, the same ones
/// translation and meeting minutes use.
struct OpenAIDiarizationProvider: DiarizationProvider {
    let apiKey: String

    private static let model = "gpt-4o-transcribe-diarize"
    /// API limits: 25 MB of audio, and at most four enrolled voices per request.
    private static let maxSizeBytes = 25 * 1_048_576
    private static let maxKnownSpeakers = 4

    var displayName: String { "OpenAI (\(Self.model))" }

    func diarize(audioURL: URL,
                 knownSpeakers: [KnownSpeakerSample],
                 progress: @escaping @Sendable (Double) -> Void) async throws -> SpeakerDiarizationResult {
        // One remote round-trip: there is no meaningful granularity to report,
        // so `progress` is never called and the UI shows an indeterminate spinner.
        guard !apiKey.isEmpty else { throw DiarizationError.noAPIKey }

        let audio: Data
        do {
            audio = try Data(contentsOf: audioURL)
        } catch {
            throw DiarizationError.providerUnavailable(error.localizedDescription)
        }
        guard audio.count <= Self.maxSizeBytes else {
            throw DiarizationError.fileTooLarge(bytes: audio.count, limit: Self.maxSizeBytes)
        }

        // Only voices with a sample still on disk are worth sending, and the API
        // caps how many it accepts — the most recently used speakers win.
        let enrolled = Array(
            knownSpeakers
                .filter { !$0.name.isEmpty && FileManager.default.fileExists(atPath: $0.fileURL.path) }
                .prefix(Self.maxKnownSpeakers))

        var request = URLRequest(url: try Self.endpointURL())
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // Diarizing a long recording server-side takes minutes; the default 60s
        // would time out well before the API answers.
        request.timeoutInterval = 600

        let boundary = "WhisperASRDiarization-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(boundary: boundary,
                                              audio: audio,
                                              fileName: audioURL.lastPathComponent,
                                              audioMimeType: Self.mimeType(for: audioURL),
                                              knownSpeakers: enrolled)

        try Task.checkCancellation()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        } catch {
            throw DiarizationError.providerUnavailable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DiarizationError.providerUnavailable("the API returned an unreadable response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "no details"
            throw DiarizationError.api(status: http.statusCode, message: message)
        }

        return try Self.parse(data, knownSpeakers: enrolled)
    }

    // MARK: - Request

    /// Same base endpoint as translation, so one API setting serves both.
    private static func endpointURL() throws -> URL {
        guard let url = TranslationService.apiURL(appending: "audio/transcriptions") else {
            throw DiarizationError.providerUnavailable("invalid API endpoint URL")
        }
        return url
    }

    /// Hand-rolled multipart body, matching how `MultipartParser` reads the ones
    /// the local API server receives. No `language` field is sent: the transcript
    /// already exists, so letting the model auto-detect avoids mislabeling a
    /// recording whose language differs from any app setting.
    private static func multipartBody(boundary: String,
                                      audio: Data,
                                      fileName: String,
                                      audioMimeType: String,
                                      knownSpeakers: [KnownSpeakerSample]) -> Data {
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(audioMimeType)\r\n\r\n")
        body.append(audio)
        append("\r\n")

        for (name, value) in [("model", model),
                              ("response_format", "diarized_json"),
                              ("chunking_strategy", "auto")] {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        // Names and references are positional: the API pairs them by index, so
        // both lists are written in the same order.
        for speaker in knownSpeakers {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"known_speaker_names[]\"\r\n\r\n")
            append("\(speaker.name)\r\n")
        }
        for speaker in knownSpeakers {
            guard let sample = try? Data(contentsOf: speaker.fileURL) else { continue }
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"known_speaker_references[]\"\r\n\r\n")
            append("data:\(mimeType(for: speaker.fileURL));base64,\(sample.base64EncodedString())\r\n")
        }

        append("--\(boundary)--\r\n")
        return body
    }

    // MARK: - Response

    private static func parse(_ data: Data,
                              knownSpeakers: [KnownSpeakerSample]) throws -> SpeakerDiarizationResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let segments = json["segments"] as? [[String: Any]] else {
            throw DiarizationError.providerUnavailable("the API returned a malformed diarized_json response")
        }

        // The API echoes back the names it was enrolled with, so a label that
        // matches one is a recognized library speaker.
        let idsByName = Dictionary(knownSpeakers.map { ($0.name.lowercased(), $0.speakerID) },
                                   uniquingKeysWith: { first, _ in first })

        let turns = segments.compactMap { segment -> SpeakerTurn? in
            guard let start = segment["start"] as? Double,
                  let end = segment["end"] as? Double,
                  let label = segment["speaker"] as? String else { return nil }
            return SpeakerTurn(start: start, end: end, label: label,
                               speakerID: idsByName[label.lowercased()])
        }
        return SpeakerDiarizationResult(turns: turns)
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp3":         return "audio/mpeg"
        case "m4a", "mp4":  return "audio/mp4"
        case "wav":         return "audio/wav"
        case "ogg":         return "audio/ogg"
        case "flac":        return "audio/flac"
        case "webm":        return "audio/webm"
        default:            return "application/octet-stream"
        }
    }
}
