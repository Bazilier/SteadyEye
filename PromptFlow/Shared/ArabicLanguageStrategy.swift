import Foundation

/// Handles Arabic, Hebrew, and Farsi scripts.
/// Space-based splitting, no glue words, no abbreviations.
/// RTL rendering handled automatically by SwiftUI Text.
struct ArabicLanguageStrategy: LanguageStrategy, Sendable {

    let maxChunkLength = 10
    var supportsORP: Bool { false }

    func endsSentence(_ word: String) -> Bool {
        word.hasSuffix(".") || word.hasSuffix("!") || word.hasSuffix("?") ||
        word.hasSuffix("؟") || word.hasSuffix("۔")
    }

    func isAbbreviation(_ chunk: String) -> Bool { false }

    func duration(for chunk: String, msPerChar: Double) -> TimeInterval {
        var cleaned = chunk
        if cleaned.hasPrefix("...") { cleaned = String(cleaned.dropFirst(3)) }
        if cleaned.hasSuffix("...") { cleaned = String(cleaned.dropLast(3)) }
        return Double(cleaned.count) * msPerChar / 1000.0
    }

    func chunks(from text: String) -> [String] {
        let words = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        return words.flatMap { word -> [String] in
            if word == "//" { return [word] }
            return splitLongWord(word)
        }
    }

    private func splitLongWord(_ word: String, maxChars: Int = 8) -> [String] {
        guard word.count > 12 else { return [word] }

        var parts: [String] = []
        var remaining = word

        while remaining.count > maxChars {
            let splitIndex = remaining.index(remaining.startIndex, offsetBy: maxChars)
            let part = String(remaining[..<splitIndex])
            remaining = String(remaining[splitIndex...])

            if parts.isEmpty {
                parts.append(part + "...")
            } else {
                parts.append("..." + part + "...")
            }
        }

        if parts.isEmpty {
            parts.append(remaining)
        } else {
            parts.append("..." + remaining)
        }

        return parts
    }
}
