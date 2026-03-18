import Foundation

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

Step 3 — Visual formatting:
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
}
