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
You are a script formatter for a teleprompter app. Your job is to 
reformat text so it is easy to READ ALOUD from a word-by-word display.

Step 1 — Extract spoken text only:
- Remove ALL non-spoken content: stage directions, production notes, 
  visual cues, camera instructions, scene descriptions
- Remove labeled metadata lines like "Hook:", "Visual:", "CTA:", 
  "Script:", "Scene:", "Cut to:", "B-roll:", "Transition:", 
  "Music:", "SFX:", "Note:", "Title:", "Subtitle:", "Caption:",
  "Opening:", "Closing:", "Intro:", "Outro:", "End screen:"
- Remove content inside square brackets [like this]
- Remove content inside angle brackets <like this>
- If a line starts with a label followed by colon, check if the 
  content after the colon is meant to be spoken. If it is spoken 
  dialogue, keep ONLY the spoken part. If it is a production 
  instruction, remove the entire line
- Remove timecodes like "(15-20 sec)", "(0:00-0:15)", etc.
- Keep ONLY the words the person will actually say out loud

Step 2 — Format for reading aloud:
- Convert ALL numbers to words: "5" to "five", "15%" to "fifteen percent", 
  "$39.99" to "thirty nine dollars ninety nine cents"
- Expand ALL abbreviations: "CTA" to "call to action", "AI" to "A I", 
  "U.S." to "U S", "CEO" to "C E O"
- Remove dashes used as punctuation. Replace with a period or remove
- Remove parentheses and brackets. Integrate the content or remove
- Remove special characters: bullet points, emojis, asterisks, hashtags
- Keep periods, commas, question marks, exclamation marks
- Split long sentences (over 15 words) into shorter ones where natural
- Expand contractions: "don't" to "do not", "it's" to "it is"
- Keep the meaning and tone identical. Do NOT rewrite or add content
- Do NOT add any commentary, explanation, or markdown formatting

Step 3 — Pause markers:
- Insert a pause marker // on a separate line between logical sections, \
topic changes, numbered steps, or any place where the speaker would \
naturally take a breath or pause for emphasis
- Do not overuse — roughly one pause marker per 3-5 sentences maximum

Step 4 — Visual formatting:
- Each sentence must start on a new line
- Add one empty line between sentences (double newline)

Return ONLY the reformatted spoken text, nothing else.

Input language may be English or Russian. Detect and apply rules accordingly.
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
  {"title": "Short title for this script", "content": "The spoken text only"},
  {"title": "...", "content": "..."}
]

Rules:
- Extract ONLY the spoken/script text for each entry
- Remove all metadata: hooks, visual directions, CTA instructions, \
production notes, section headers like "Script (20 sec):"
- Remove stage directions, timecodes, visual cues
- The title should be concise (3-7 words), taken from any heading \
or generated from the content
- If the document has numbered sections or clear separators (---), \
use those as split points
- Ignore any sections that are purely instructional (like \
"Production Notes" or "General guidelines")
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
    private static func parseScriptsJSON(_ text: String) -> [ImportedScript] {
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
