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
        let effectiveChars: Double
        if isAbbreviation(chunk) {
            let trimmed = chunk.trimmingCharacters(in: .punctuationCharacters)
            effectiveChars = Double(trimmed.filter { $0.isLetter }.count) * 3.0
        } else {
            effectiveChars = Double(chunk.count)
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

        return result
    }
}
