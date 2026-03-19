import Foundation

/// Splits a script into display chunks using glue-word grouping rules,
/// and computes per-chunk display durations.
enum WordChunkEngine {

    // MARK: - Glue words

    /// Short function words that should attach to the following word.
    static let glueWords: Set<String> = [
        "a", "an", "the",
        "in", "on", "at", "to", "of", "for", "by", "with",
        "and", "but", "or",
        "is", "it", "as", "if",
        "no", "not", "so",
        "my", "his", "her", "its", "our", "your",
        "this", "that"
    ]

    // MARK: - Chunk building

    /// Maximum characters (including spaces) allowed in a single chunk.
    static let maxChunkLength = 10

    /// Returns true if a word ends with sentence-ending punctuation (. ! ? ...).
    private static func endsSentence(_ word: String) -> Bool {
        word.hasSuffix(".") || word.hasSuffix("!") || word.hasSuffix("?")
    }

    /// Splits text into word groups. Glue words attach to following words
    /// only if the combined chunk stays within `maxChunkLength`.
    /// Sentence-ending punctuation always closes the current chunk.
    static func chunks(from text: String) -> [String] {
        let words = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        var result: [String] = []
        var i = 0

        while i < words.count {
            var group = words[i]
            i += 1

            // If word ends a sentence, close chunk immediately
            if endsSentence(group) {
                result.append(group)
                continue
            }

            // Only try to attach more words if the current word is a glue word
            let bare = group.lowercased().trimmingCharacters(in: .punctuationCharacters)
            guard glueWords.contains(bare) else {
                result.append(group)
                continue
            }

            // Consume subsequent glue words while under the limit
            while i < words.count {
                let nextBare = words[i].lowercased().trimmingCharacters(in: .punctuationCharacters)
                guard glueWords.contains(nextBare) else { break }
                let candidate = group + " " + words[i]
                guard candidate.count <= maxChunkLength else { break }
                group = candidate
                i += 1
                if endsSentence(words[i - 1]) { break }
            }

            // Try to attach exactly one non-glue word (unless chunk already ends a sentence)
            if !endsSentence(group), i < words.count {
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

    // MARK: - Continuous speed

    /// Converts a 0…1 slider value to milliseconds per character.
    /// 0.0 = slowest (80ms), 1.0 = fastest (12ms).
    /// Exponential mapping gives more resolution in the fast range.
    static func msPerChar(forSlider value: Double) -> Double {
        80.0 * pow(0.15, value)
    }

    // MARK: - Display duration

    /// Duration a chunk should be displayed, given a slider value (0…1).
    static func duration(for chunk: String, sliderValue: Double) -> TimeInterval {
        let ms = msPerChar(forSlider: sliderValue) * Double(chunk.count)
        let clampedMs = max(250.0, min(2000.0, ms))
        return clampedMs / 1000.0
    }

    /// Duration of the blank gap shown between chunks (seconds).
    static func gapDuration(sliderValue: Double) -> TimeInterval {
        // Slower → longer gap, faster → shorter gap
        let gap = 0.12 - 0.08 * sliderValue
        return max(0.03, gap)
    }
}
