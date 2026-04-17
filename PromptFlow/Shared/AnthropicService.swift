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
    
    private static let systemPrompt: String = loadPrompt("FormatPrompt")
    
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
    
    private static let splitSystemPrompt: String = loadPrompt("SplitPrompt")
    
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

    private static func loadPrompt(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            assertionFailure("Missing prompt file: \(name).txt")
            return ""
        }
        return text
    }
}
