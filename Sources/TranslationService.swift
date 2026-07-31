import Foundation

struct TargetLanguage: Identifiable, Hashable {
    let id: String        // locale identifier (e.g. "en", "zh-Hans")
    let name: String      // English name (used in API prompts)
    let nativeName: String // native name (displayed in UI)

    static let available: [TargetLanguage] = [
        .init(id: "en", name: "English", nativeName: "English"),
        .init(id: "zh-Hans", name: "Chinese (Simplified)", nativeName: "简体中文"),
        .init(id: "zh-Hant", name: "Chinese (Traditional)", nativeName: "繁體中文"),
        .init(id: "ja", name: "Japanese", nativeName: "日本語"),
        .init(id: "ko", name: "Korean", nativeName: "한국어"),
        .init(id: "es", name: "Spanish", nativeName: "Español"),
        .init(id: "fr", name: "French", nativeName: "Français"),
        .init(id: "de", name: "German", nativeName: "Deutsch"),
        .init(id: "pt", name: "Portuguese", nativeName: "Português"),
        .init(id: "ru", name: "Russian", nativeName: "Русский"),
        .init(id: "ar", name: "Arabic", nativeName: "العربية"),
        .init(id: "hi", name: "Hindi", nativeName: "हिन्दी"),
        .init(id: "th", name: "Thai", nativeName: "ภาษาไทย"),
        .init(id: "vi", name: "Vietnamese", nativeName: "Tiếng Việt"),
        .init(id: "it", name: "Italian", nativeName: "Italiano"),
        .init(id: "nl", name: "Dutch", nativeName: "Nederlands"),
        .init(id: "pl", name: "Polish", nativeName: "Polski"),
        .init(id: "uk", name: "Ukrainian", nativeName: "Українська"),
        .init(id: "tr", name: "Turkish", nativeName: "Türkçe"),
        .init(id: "id", name: "Indonesian", nativeName: "Bahasa Indonesia"),
    ]
}

enum TranslationError: LocalizedError {
    case invalidEndpoint
    case apiFailed(String)
    case authFailed(String)
    case rateLimited(String)
    case serverError(Int, String)
    case transport(String)
    case parseError
    case unavailable

    // Worded generically ("API error", not "Translation API error") because the
    // meeting-minutes feature shares this client and surfaces the same errors.
    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Invalid API endpoint URL"
        case .apiFailed(let msg): return "API error: \(msg)"
        case .authFailed(let msg): return "API key invalid or unauthorized: \(msg)"
        case .rateLimited(let msg): return "Rate-limited by the API: \(msg)"
        case .serverError(let code, let msg): return "API service error (HTTP \(code)): \(msg)"
        case .transport(let msg): return "Network error: \(msg)"
        case .parseError: return "Failed to parse the API response"
        case .unavailable: return "Requires an OpenAI-compatible API — set the API key in Settings"
        }
    }

    /// Whether the error is worth retrying (transient). Auth/client errors are not.
    var isRetriable: Bool {
        switch self {
        case .serverError, .transport: return true
        case .invalidEndpoint, .apiFailed, .authFailed, .rateLimited, .parseError, .unavailable: return false
        }
    }
}

enum TranslationService {
    /// Builds a request URL from the user's configured endpoint (defaulting to
    /// OpenAI), appending `path` unless the endpoint already ends with it. One
    /// "OpenAI API" setting serves every consumer — translation, meeting minutes
    /// and remote diarization — so the endpoint is derived in exactly one place.
    static func apiURL(appending path: String) -> URL? {
        let endpoint = (UserDefaults.standard.string(forKey: "translationEndpoint") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var base = endpoint.isEmpty ? "https://api.openai.com/v1" : endpoint
        if !base.hasSuffix(path) {
            if !base.hasSuffix("/") { base += "/" }
            base += path
        }
        return URL(string: base)
    }

    static func translateSegmentsWithOpenAI(
        segmentTexts: [String],
        targetLanguage: String,
        previousTranslations: [(original: String, translated: String)] = []
    ) async throws -> [String] {
        guard !segmentTexts.isEmpty else { return [] }

        let apiKey = UserDefaults.standard.string(forKey: "translationAPIKey") ?? ""
        let model = (UserDefaults.standard.string(forKey: "translationModel") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveModel = model.isEmpty ? "gpt-4o-mini" : model

        guard let url = apiURL(appending: "chat/completions") else {
            throw TranslationError.invalidEndpoint
        }

        let languageName = TargetLanguage.available.first { $0.id == targetLanguage }?.name ?? targetLanguage

        let numberedInput = segmentTexts.enumerated()
            .map { "\($0.offset + 1). \($0.element.trimmingCharacters(in: .whitespaces))" }
            .joined(separator: "\n")

        // Build context section from previous translations
        var contextSection = ""
        if !previousTranslations.isEmpty {
            let pairs = previousTranslations.suffix(2)
                .map { "\"\($0.original)\" → \"\($0.translated)\"" }
                .joined(separator: "\n")
            contextSection = "\n\nPreviously translated segments from this conversation (use as reference for consistent terminology and style):\n\(pairs)"
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": effectiveModel,
            "messages": [
                ["role": "system", "content": "You are a translator for a live transcription. Translate each numbered line to \(languageName). If a line is already in \(languageName), output it unchanged. Output ONLY the translations in the same numbered format (e.g. \"1. ...\"). Keep exactly \(segmentTexts.count) lines.\(contextSection)"],
                ["role": "user", "content": numberedInput]
            ],
            "temperature": 0.3
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await performRequestWithRetry(request)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TranslationError.parseError
        }

        // Parse numbered lines, stripping the "1. " prefix
        let lines = content.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { line -> String in
                if let range = line.range(of: #"^\d+\.\s*"#, options: .regularExpression) {
                    return String(line[range.upperBound...])
                }
                return line
            }

        // Pad or trim to match input count
        if lines.count >= segmentTexts.count {
            return Array(lines.prefix(segmentTexts.count))
        } else {
            return lines + Array(repeating: "", count: segmentTexts.count - lines.count)
        }
    }

    /// Send the request with up to 2 retries (3 attempts total) for transient failures
    /// (URLSession transport errors and 5xx). Auth/client errors are never retried.
    /// Shared with MeetingMinutesService, which talks to the same API.
    static func performRequestWithRetry(_ request: URLRequest) async throws -> Data {
        let backoffs: [Duration] = [.milliseconds(500), .milliseconds(1500)]
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await performRequest(request)
            } catch let err as TranslationError where err.isRetriable && attempt < backoffs.count {
                try? await Task.sleep(for: backoffs[attempt])
                attempt += 1
                continue
            }
        }
    }

    private static func performRequest(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw TranslationError.transport(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationError.transport("Invalid response")
        }
        if (200...299).contains(httpResponse.statusCode) {
            return data
        }

        let message = parseErrorMessage(data) ?? "HTTP \(httpResponse.statusCode)"
        switch httpResponse.statusCode {
        case 401, 403:
            throw TranslationError.authFailed(message)
        case 429:
            throw TranslationError.rateLimited(message)
        case 500...599:
            throw TranslationError.serverError(httpResponse.statusCode, message)
        default:
            throw TranslationError.apiFailed(message)
        }
    }

    /// Extract `error.message` from an OpenAI-style error body.
    private static func parseErrorMessage(_ data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = json["error"] as? [String: Any],
            let message = error["message"] as? String,
            !message.isEmpty
        else { return nil }
        return message
    }
}
