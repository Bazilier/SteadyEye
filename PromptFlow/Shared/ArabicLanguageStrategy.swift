import Foundation

/// Handles Arabic, Hebrew, and Farsi scripts.
/// Space-based splitting (same as Latin), no glue words, no abbreviations.
/// Note: RTL rendering is handled automatically by SwiftUI Text.
struct ArabicLanguageStrategy: LanguageStrategy, Sendable {

    let maxChunkLength = 10

    func endsSentence(_ word: String) -> Bool {
        word.hasSuffix(".") || word.hasSuffix("!") || word.hasSuffix("?") ||
        word.hasSuffix("؟") || word.hasSuffix("۔")
    }

    func isAbbreviation(_ chunk: String) -> Bool {
        false  // Arabic has no uppercase concept
    }

    func duration(for chunk: String, msPerChar: Double) -> TimeInterval {
        return Double(chunk.count) * msPerChar / 1000.0
    }

    func chunks(from text: String) -> [String] {
        let words = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        var result: [String] = []

        for word in words {
            if word == "//" {
                result.append(word)
                continue
            }
            result.append(word)
        }

        return result
    }
}
