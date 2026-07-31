import Foundation
import Observation

// MARK: - Minutes Prompt

/// A user-configurable instruction template for generating meeting minutes.
struct MinutesPrompt: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var prompt: String
}

// MARK: - Prompt Store

/// Owns the minutes prompt templates (persisted as JSON in UserDefaults) and
/// the currently selected template. Always contains at least one prompt — the
/// built-in default is re-seeded if the user deletes everything.
@MainActor
@Observable
final class MinutesPromptStore {
    static let shared = MinutesPromptStore()

    // nonisolated: BackupService reads these from nonisolated code.
    nonisolated static let promptsKey = "minutesPrompts"
    nonisolated static let selectedKey = "selectedMinutesPromptID"
    nonisolated static let contextTokensKey = "minutesContextTokens"
    nonisolated static let defaultContextTokens = 16_000

    var prompts: [MinutesPrompt]
    var selectedPromptID: UUID? {
        didSet {
            UserDefaults.standard.set(selectedPromptID?.uuidString, forKey: Self.selectedKey)
        }
    }

    private init() {
        prompts = Self.loadPrompts()
        if let raw = UserDefaults.standard.string(forKey: Self.selectedKey) {
            selectedPromptID = UUID(uuidString: raw)
        }
    }

    /// The template used when generating without an explicit choice.
    var selectedPrompt: MinutesPrompt {
        prompts.first { $0.id == selectedPromptID } ?? prompts[0]
    }

    func upsert(_ prompt: MinutesPrompt) {
        if let idx = prompts.firstIndex(where: { $0.id == prompt.id }) {
            prompts[idx] = prompt
        } else {
            prompts.append(prompt)
        }
        persist()
    }

    func delete(_ prompt: MinutesPrompt) {
        prompts.removeAll { $0.id == prompt.id }
        if prompts.isEmpty {
            prompts = [Self.defaultPrompt()]
        }
        if selectedPromptID == prompt.id {
            selectedPromptID = prompts[0].id
        }
        persist()
    }

    /// Re-read from UserDefaults after an external write (backup restore).
    func reloadFromDefaults() {
        prompts = Self.loadPrompts()
        if let raw = UserDefaults.standard.string(forKey: Self.selectedKey) {
            selectedPromptID = UUID(uuidString: raw)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(prompts) {
            UserDefaults.standard.set(data, forKey: Self.promptsKey)
        }
    }

    private static func loadPrompts() -> [MinutesPrompt] {
        if let data = UserDefaults.standard.data(forKey: promptsKey),
           let decoded = try? JSONDecoder().decode([MinutesPrompt].self, from: data),
           !decoded.isEmpty {
            return decoded
        }
        return [defaultPrompt()]
    }

    static func defaultPrompt() -> MinutesPrompt {
        MinutesPrompt(
            name: "Default Meeting Minutes",
            prompt: """
            Write structured meeting minutes from the transcript. Include:

            - Meeting title: a short descriptive title inferred from the content
            - Overview: a 2-4 sentence summary of the meeting's purpose and outcome
            - Key discussion points: grouped by topic, with the important arguments and context
            - Decisions made: each decision with its rationale
            - Action items: a table of task, owner (if identifiable), and deadline (if mentioned)
            - Open questions: unresolved issues to follow up on

            Write the minutes in the same language as the transcript. Be faithful to the \
            content; do not invent details that are not in the transcript. Omit any section \
            that has no content.
            """
        )
    }

    /// The configured model context window, floored to something workable.
    static func contextTokens() -> Int {
        let stored = UserDefaults.standard.integer(forKey: contextTokensKey)
        let value = stored == 0 ? defaultContextTokens : stored
        return max(4_000, value)
    }
}

// MARK: - Minutes Generation Service

/// Generates meeting minutes from a transcript via the same OpenAI-compatible
/// chat API configured for translation. Transcripts that exceed the configured
/// context window are map-reduced: per-chunk note extraction, hierarchical
/// condensation if needed, then a final pass that applies the user's prompt.
enum MeetingMinutesService {

    /// Tokens reserved for the response and prompt overhead within the context window.
    private static let outputReserveTokens = 2_048

    private static let minutesSystemPrompt = """
    You are a professional meeting-minutes writer. Follow the user's instructions to \
    produce meeting minutes from a transcript.
    Output rules:
    - Respond with ONLY an HTML fragment (the content that would go inside <body>). \
    No markdown, no code fences, no <html>, <head> or <body> tags.
    - Use semantic HTML: <h1> for the title, <h2> for section headings, <p> for prose, \
    <ul>/<ol> for lists, and <table> with <thead>/<tbody> for tabular data such as action items.
    - Write in the same language as the transcript unless the instructions say otherwise.
    """

    private static func notesSystemPrompt(part: Int, of total: Int) -> String {
        """
        You are processing part \(part) of \(total) of a long meeting transcript. \
        Extract detailed notes in plain text bullet points, preserving: topics discussed, \
        who said what (when identifiable), decisions, action items, numbers, dates, and names. \
        Write the notes in the same language as the transcript. Do not write final minutes yet; \
        output only the notes.
        """
    }

    private static let condenseSystemPrompt = """
    You are condensing meeting notes that are too long to process at once. Merge the notes \
    into a shorter set of plain-text bullet points, keeping every decision, action item, \
    number, date, and name. Write in the same language as the notes. Output only the notes.
    """

    /// Generate minutes and return an HTML fragment.
    static func generateMinutes(
        transcriptLines: [String],
        instructions: String,
        contextTokens: Int,
        onProgress: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let inputBudget = max(1_024, contextTokens - outputReserveTokens)
        let transcript = transcriptLines.joined(separator: "\n")

        if estimatedTokens(transcript) <= inputBudget {
            await onProgress("Writing minutes…")
            return try await chat(
                system: minutesSystemPrompt,
                user: instructions + "\n\nTranscript:\n" + transcript)
        }

        // Map: extract notes from each chunk.
        let chunks = chunk(lines: transcriptLines, budget: inputBudget)
        var notes: [String] = []
        for (i, part) in chunks.enumerated() {
            try Task.checkCancellation()
            await onProgress("Summarizing part \(i + 1) of \(chunks.count)…")
            notes.append(try await chat(
                system: notesSystemPrompt(part: i + 1, of: chunks.count),
                user: part))
        }

        // Reduce hierarchically until the merged notes fit the budget.
        var rounds = 0
        while notes.count > 1, estimatedTokens(notes.joined(separator: "\n\n")) > inputBudget, rounds < 3 {
            try Task.checkCancellation()
            await onProgress("Condensing notes…")
            let groups = chunk(lines: notes, budget: inputBudget)
            var condensed: [String] = []
            for group in groups {
                try Task.checkCancellation()
                condensed.append(try await chat(system: condenseSystemPrompt, user: group))
            }
            notes = condensed
            rounds += 1
        }

        try Task.checkCancellation()
        await onProgress("Writing minutes…")
        return try await chat(
            system: minutesSystemPrompt,
            user: instructions
                + "\n\nThe meeting transcript was too long to process at once; below are "
                + "sequential notes extracted from each part. Write the minutes from these notes.\n\nNotes:\n"
                + notes.joined(separator: "\n\n"))
    }

    // MARK: Token estimation & chunking

    /// Rough token count: CJK characters ≈ 1 token each, everything else ≈ 3
    /// characters per token. Deliberately overestimates so chunks stay safely
    /// inside the context window.
    static func estimatedTokens(_ text: String) -> Int {
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x2E80...0x9FFF,     // CJK radicals, kana, CJK unified
                 0xAC00...0xD7AF,     // Hangul syllables
                 0xF900...0xFAFF,     // CJK compatibility
                 0xFF00...0xFFEF,     // full-width forms
                 0x20000...0x2FA1F:   // CJK extensions
                cjk += 1
            default:
                other += 1
            }
        }
        return cjk + other / 3
    }

    /// Greedily pack lines into chunks of at most `budget` estimated tokens.
    /// A single line longer than the budget becomes its own chunk (transcript
    /// segments are short, so this is a safety valve, not an expected path).
    static func chunk(lines: [String], budget: Int) -> [String] {
        var chunks: [String] = []
        var current: [String] = []
        var currentTokens = 0
        for line in lines {
            let tokens = estimatedTokens(line) + 1
            if !current.isEmpty, currentTokens + tokens > budget {
                chunks.append(current.joined(separator: "\n"))
                current = []
                currentTokens = 0
            }
            current.append(line)
            currentTokens += tokens
        }
        if !current.isEmpty {
            chunks.append(current.joined(separator: "\n"))
        }
        return chunks
    }

    // MARK: Chat call

    /// One chat-completion round-trip using the OpenAI API settings shared with
    /// translation (endpoint / key / model UserDefaults keys).
    private static func chat(system: String, user: String) async throws -> String {
        let apiKey = UserDefaults.standard.string(forKey: "translationAPIKey") ?? ""
        let model = (UserDefaults.standard.string(forKey: "translationModel") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw TranslationError.unavailable
        }

        guard let url = TranslationService.apiURL(appending: "chat/completions") else {
            throw TranslationError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // Minutes responses are long-form; allow far more time than translation.
        request.timeoutInterval = 300

        let body: [String: Any] = [
            "model": model.isEmpty ? "gpt-4o-mini" : model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "temperature": 0.3
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await TranslationService.performRequestWithRetry(request)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TranslationError.parseError
        }
        return stripCodeFences(content)
    }

    /// Models sometimes wrap output in ``` fences despite instructions; unwrap them.
    static func stripCodeFences(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.hasPrefix("```") else { return result }
        if let newline = result.firstIndex(of: "\n") {
            result = String(result[result.index(after: newline)...])
        }
        if result.hasSuffix("```") {
            result = String(result.dropLast(3))
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Minutes Generator (UI state)

/// Main-actor state for the Meeting Minutes window: the current generation
/// task, its phase, and the produced HTML. A singleton because the app has a
/// single minutes window; a new generation replaces the previous result.
@MainActor
@Observable
final class MinutesGenerator {
    static let shared = MinutesGenerator()

    enum Phase: Equatable {
        case idle
        case generating(String)   // human-readable progress status
        case completed
        case failed(String)
    }

    var phase: Phase = .idle
    /// The generated minutes as an HTML fragment (body content only).
    var htmlFragment: String = ""
    var itemName: String = ""
    var promptName: String = ""
    /// The transcription item the current minutes belong to.
    var sourceItemID: UUID?

    private var task: Task<Void, Never>?
    /// Identifies the current generation so a superseded task's late progress
    /// or result can't clobber the newer one.
    private var generation = UUID()

    private init() {}

    /// A complete, self-contained HTML document for the webview / export.
    var fullHTMLDocument: String {
        Self.wrapHTML(fragment: htmlFragment, title: itemName.isEmpty ? "Meeting Minutes" : itemName)
    }

    func generate(item: TranscriptionItem, prompt: MinutesPrompt) {
        task?.cancel()
        itemName = item.fileName
        promptName = prompt.name
        sourceItemID = item.id
        htmlFragment = ""
        phase = .generating("Preparing transcript…")

        let lines: [String]
        if item.segments.isEmpty {
            lines = item.fullText
                .components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        } else {
            // speakerLine prefixes the speaker on diarized transcripts — who said
            // what is exactly the kind of detail minutes need.
            lines = item.segments.map { seg in
                "[\(Self.formatTimestamp(seg.start))] \(SubtitleFormatter.speakerLine(seg))"
            }
        }
        guard !lines.isEmpty else {
            phase = .failed("The transcript is empty.")
            return
        }

        let instructions = prompt.prompt
        let contextTokens = MinutesPromptStore.contextTokens()
        let token = UUID()
        generation = token

        task = Task { [weak self] in
            do {
                let fragment = try await MeetingMinutesService.generateMinutes(
                    transcriptLines: lines,
                    instructions: instructions,
                    contextTokens: contextTokens
                ) { [weak self] status in
                    guard let self, self.generation == token else { return }
                    self.phase = .generating(status)
                }
                guard let self, self.generation == token else { return }
                self.htmlFragment = fragment
                self.phase = .completed
            } catch is CancellationError {
                // Superseded or cancelled — the new generation owns the phase.
            } catch {
                guard let self, self.generation == token else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if case .generating = phase { phase = .idle }
    }

    private static func formatTimestamp(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: HTML shell

    static func wrapHTML(fragment: String, title: String) -> String {
        let escapedTitle = title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>\(escapedTitle)</title>
        <style>
        :root { color-scheme: light dark; }
        body {
            font-family: -apple-system, "Helvetica Neue", "PingFang TC", "Hiragino Sans", sans-serif;
            line-height: 1.6;
            max-width: 46em;
            margin: 0 auto;
            padding: 2em 1.6em 3em;
            color: #1d1d1f;
            background: #ffffff;
        }
        h1 { font-size: 1.55em; margin: 0 0 0.6em; padding-bottom: 0.35em; border-bottom: 2px solid #d2d2d7; }
        h2 { font-size: 1.15em; margin: 1.6em 0 0.5em; }
        h3 { font-size: 1.0em; margin: 1.2em 0 0.4em; }
        p { margin: 0.5em 0; }
        ul, ol { margin: 0.4em 0 0.8em; padding-left: 1.6em; }
        li { margin: 0.25em 0; }
        table { border-collapse: collapse; width: 100%; margin: 0.8em 0 1.2em; font-size: 0.95em; }
        th, td { border: 1px solid #d2d2d7; padding: 6px 10px; text-align: left; vertical-align: top; }
        th { background: #f5f5f7; font-weight: 600; }
        blockquote { margin: 0.6em 0; padding: 0.2em 1em; border-left: 3px solid #d2d2d7; color: #6e6e73; }
        @media (prefers-color-scheme: dark) {
            body { color: #e8e8ed; background: #1e1e1e; }
            h1 { border-bottom-color: #48484a; }
            th, td { border-color: #48484a; }
            th { background: #2c2c2e; }
            blockquote { border-left-color: #48484a; color: #98989d; }
        }
        </style>
        </head>
        <body>
        \(fragment)
        </body>
        </html>
        """
    }
}
