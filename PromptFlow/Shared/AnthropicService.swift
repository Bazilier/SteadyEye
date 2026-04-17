import Foundation

struct ImportedScript: Decodable {
    let title: String
    let content: String
}

enum AnthropicService {
    
    enum ServiceError: LocalizedError {
        case missingAPIKey
        case networkError(Error)
        case httpError(Int)
        case decodingError
        case emptyResponse
        
        // Developer-facing only. The user sees the wrapped message produced by
        // ScriptEditorView (`scripts.editor.error.formatFailed`) — these strings
        // are intentionally not localized.
        var errorDescription: String? {
            switch self {
            case .missingAPIKey: return "API key not configured."
            case .networkError(let e): return e.localizedDescription
            case .httpError(let code): return "Server returned status \(code)."
            case .decodingError: return "Could not parse response."
            case .emptyResponse: return "Empty response from API."
            }
        }
    }
    
    private static let systemPrompt = """
    You are a script formatter for a teleprompter app. Your job is to \
    reformat text so it is easy to READ ALOUD from a word-by-word display.

    CRITICAL: Do NOT rephrase, reword, or rewrite sentences. Keep the \
    original wording. You are a formatter, not a writer. Only apply \
    the specific formatting rules below. \
    Do NOT add greetings, commentary, explanations, or any text that \
    was not in the original input. If the input is empty, return empty. \
    NEVER translate the text. The output language must be the same as \
    the input language. If the input is in Spanish, output in Spanish. \
    If in Portuguese, output in Portuguese.

    Rules:

    1. Clean up non-spoken content:
    - Remove content inside square brackets [like this]
    - Remove content inside angle brackets <like this>
    - Remove timecodes like "(15-20 sec)", "(0:00-0:15)"

    2. Numbers and symbols:
    - Convert numbers to words: "5" to "five", "15%" to "fifteen percent", \
    "$39.99" to "thirty nine dollars and ninety nine cents"
    - Keep abbreviations people say as letters: "AI", "CEO", "SaaS", \
    "SEO", "CPC", "PDF", "CTA" stay as-is
    - Replace "=" with "is" or "are" depending on context
    - Replace "w/" with "with", "c/" with "with"
    - Replace "&" with "and", "+" with "and" when used between words
    - Replace "..." with a period
    - Expand common text abbreviations: "mktg" to "marketing", \
    "govt" to "government", "mgmt" to "management", "dev" to "development"
    - Reduce multiple exclamation/question marks to one: "!!!" to "!", "??" to "?"
    - Remove special characters: bullet points, emojis, asterisks, hashtags
    - Remove dashes used as punctuation. Replace with a period or remove
    - Remove parentheses. Integrate the content naturally or remove
    - Keep periods, commas, question marks, exclamation marks
    - Keep CAPS words as-is. They indicate emphasis the speaker wants

    3. Sentence structure:
    - Split long sentences (over 15 words) into shorter ones at natural \
    break points. Do not change the words, just add periods
    - Keep contractions as-is. "don't", "isn't", "it's", "won't" sound \
    natural when spoken. Do NOT expand them
    - Capitalize the first letter of every sentence
    - Each sentence starts on a new line
    - Add one empty line between sentences (double newline)

    4. Pause markers:
    - Insert // on a separate line between logical sections or topic \
    changes, where the speaker would naturally pause
    - Roughly one pause marker per 3-5 sentences maximum

    Return ONLY the reformatted text, nothing else.

    Input language may be any language. Detect and apply rules accordingly.

    Language-specific rules:
    - Japanese: keep kanji and katakana as-is, convert Arabic numerals \
    to Japanese words (5 to 五, 100 to 百)
    - Chinese: keep characters as-is, convert Arabic numerals to \
    Chinese (5 to 五, 100 to 一百)
    - Korean: keep text as-is, convert Arabic numerals to Korean \
    (5 to 다섯, 100 to 백)
    - Arabic: convert numbers to Arabic words
    - All other formatting rules apply to all languages
    """
    
    static func optimizeForReading(_ text: String) async throws -> String {
        guard let apiKey = SecretsManager.anthropicAPIKey() else {
            throw ServiceError.missingAPIKey
        }
        
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        
        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 2048,
            "system": systemPrompt,
            "messages": [["role": "user", "content": text]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ServiceError.networkError(error)
        }
        
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.decodingError
        }
        guard http.statusCode == 200 else {
            throw ServiceError.httpError(http.statusCode)
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let first = content.first,
              let text = first["text"] as? String
        else {
            throw ServiceError.decodingError
        }
        
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ServiceError.emptyResponse }
        return trimmed
    }
    
    // MARK: - Bulk script splitting
    
    private static let splitSystemPrompt = """
    You are a script splitter. The user will paste a document containing \
    multiple video scripts or text sections. Your job is to split them \
    into individual scripts.

    For each script found, output a JSON array:
    [
      {"title": "Short title for this script", "content": "Full raw text of this section"},
      {"title": "...", "content": "..."}
    ]

    Rules:
    - Split the document into separate scripts based on: numbered sections, \
    clear topic changes, separators (---, blank lines between blocks), \
    or headings
    - Keep the FULL raw text of each section in content, including \
    metadata, notes, numbers, abbreviations — do not clean or reformat
    - The title should be concise (3-7 words), derived from any heading \
    present or generated from the content topic
    - Generate the title in the same language as the content. \
    If the content is in Spanish, the title must be in Spanish. \
    If in Portuguese, the title must be in Portuguese. Never \
    default to English unless the content is in English.
    - If the document has no clear separators but covers multiple \
    distinct topics, split by topic change
    - If the document contains only one topic, return a single-item array
    - Ignore sections that are purely instructional and not meant to be \
    spoken (like "Production Notes" or "General guidelines")
    - Return ONLY valid JSON, no markdown, no backticks, no explanation
    """
    
    static func splitScripts(_ text: String) async throws -> [ImportedScript] {
        guard let apiKey = SecretsManager.anthropicAPIKey() else {
            throw ServiceError.missingAPIKey
        }
        
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        
        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 8192,
            "system": splitSystemPrompt,
            "messages": [["role": "user", "content": text]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ServiceError.networkError(error)
        }
        
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.decodingError
        }
        guard http.statusCode == 200 else {
            throw ServiceError.httpError(http.statusCode)
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let first = content.first,
              let responseText = first["text"] as? String
        else {
            throw ServiceError.decodingError
        }
        
        return parseScriptsJSON(responseText)
    }
    
    /// Parses JSON array from the API response, handling markdown fences and edge cases.
    static func parseScriptsJSON(_ text: String) -> [ImportedScript] {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Strip markdown code fences if present
        if cleaned.hasPrefix("```") {
            if let firstNewline = cleaned.firstIndex(of: "\n") {
                cleaned = String(cleaned[cleaned.index(after: firstNewline)...])
            }
            if cleaned.hasSuffix("```") {
                cleaned = String(cleaned.dropLast(3))
            }
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        // Try to find JSON array boundaries
        if let start = cleaned.firstIndex(of: "["),
           let end = cleaned.lastIndex(of: "]") {
            cleaned = String(cleaned[start...end])
        }
        
        guard let data = cleaned.data(using: .utf8),
              let scripts = try? JSONDecoder().decode([ImportedScript].self, from: data),
              !scripts.isEmpty
        else {
            return []
        }
        
        return scripts.filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
