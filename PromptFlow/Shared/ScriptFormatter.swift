import Foundation

/// Local second-pass formatter that catches anything the AI missed.
enum ScriptFormatter {

    /// Clean up AI-formatted text: remove dashes, brackets, special chars,
    /// normalize whitespace while preserving double-newline sentence spacing.
    static func cleanUp(_ text: String) -> String {
        var result = text

        // Remove dashes used as punctuation (em dash, en dash, hyphen surrounded by spaces)
        result = result.replacingOccurrences(of: "—", with: " ")
        result = result.replacingOccurrences(of: "–", with: " ")
        // Hyphen between spaces (punctuation dash), but not inside words like "well-known"
        result = result.replacingOccurrences(
            of: "\\s-\\s",
            with: " ",
            options: .regularExpression
        )

        // Remove brackets and parentheses and their contents if any remain
        // [anything] or (anything) — remove entirely
        result = result.replacingOccurrences(
            of: "\\[.*?\\]",
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "\\(.*?\\)",
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "<.*?>",
            with: "",
            options: .regularExpression
        )
        // Remove any stray brackets/parens
        for char in "[](){}<>" {
            result = result.replacingOccurrences(of: String(char), with: "")
        }

        // Remove special characters (bullets, asterisks, hashtags, etc.)
        for char in "•●○◦▪▸►★☆✓✗✔✘#*~`|" {
            result = result.replacingOccurrences(of: String(char), with: "")
        }

        // Preserve paragraph breaks: split on double+ newlines first
        let paragraphs = result.components(separatedBy: "\n\n")
        let cleaned = paragraphs.map { paragraph -> String in
            // Within each paragraph, collapse whitespace and newlines
            paragraph
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        .filter { !$0.isEmpty }

        result = cleaned.joined(separator: "\n\n")

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
