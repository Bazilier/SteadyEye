import Foundation

/// Handles English, Russian, and European languages.
/// Space-based word splitting with glue-word grouping.
struct LatinLanguageStrategy: LanguageStrategy, Sendable {

    static let glueWords: Set<String> = [
        "a", "an", "the",
        "in", "on", "at", "to", "of", "for", "by", "with",
        "and", "but", "or",
        "is", "it", "as", "if",
        "no", "not", "so",
        "my", "his", "her", "its", "our", "your",
        "this", "that"
    ]

    let maxChunkLength = 10

    func endsSentence(_ word: String) -> Bool {
        word.hasSuffix(".") || word.hasSuffix("!") || word.hasSuffix("?")
    }

    func isAbbreviation(_ chunk: String) -> Bool {
        let trimmed = chunk.trimmingCharacters(in: .punctuationCharacters)
        return trimmed.count >= 2 && trimmed.count <= 6
            && trimmed == trimmed.uppercased()
            && trimmed != trimmed.lowercased()
            && trimmed.allSatisfy({ $0.isLetter || $0 == "." })
    }

    func duration(for chunk: String, msPerChar: Double) -> TimeInterval {
        // Strip ellipsis from split words before counting
        var cleaned = chunk
        if cleaned.hasPrefix("...") { cleaned = String(cleaned.dropFirst(3)) }
        if cleaned.hasSuffix("...") { cleaned = String(cleaned.dropLast(3)) }

        let effectiveChars: Double
        if isAbbreviation(cleaned) {
            let trimmed = cleaned.trimmingCharacters(in: .punctuationCharacters)
            effectiveChars = Double(trimmed.filter { $0.isLetter }.count) * 3.0
        } else {
            effectiveChars = Double(cleaned.count)
        }
        return effectiveChars * msPerChar / 1000.0
    }

    func chunks(from text: String) -> [String] {
        let words = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        var result: [String] = []
        var i = 0

        while i < words.count {
            var group = words[i]
            i += 1

            // Pause marker
            if group == "//" {
                result.append(group)
                continue
            }

            // Sentence end closes chunk
            if endsSentence(group) {
                result.append(group)
                continue
            }

            // Glue word logic
            let bare = group.lowercased().trimmingCharacters(in: .punctuationCharacters)
            guard Self.glueWords.contains(bare) else {
                result.append(group)
                continue
            }

            // Consume subsequent glue words
            while i < words.count {
                guard words[i] != "//" else { break }
                let nextBare = words[i].lowercased().trimmingCharacters(in: .punctuationCharacters)
                guard Self.glueWords.contains(nextBare) else { break }
                let candidate = group + " " + words[i]
                guard candidate.count <= maxChunkLength else { break }
                group = candidate
                i += 1
                if endsSentence(words[i - 1]) { break }
            }

            // Attach one non-glue word
            if !endsSentence(group), i < words.count, words[i] != "//" {
                let candidate = group + " " + words[i]
                if candidate.count <= maxChunkLength {
                    group = candidate
                    i += 1
                }
            }

            result.append(group)
        }

        // Post-process: split long single words
        return result.flatMap { chunk -> [String] in
            if chunk == "//" { return [chunk] }
            if chunk.contains(" ") { return [chunk] }
            return splitLongWord(chunk)
        }
    }

    // MARK: - Long word splitting

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
