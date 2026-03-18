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

    /// Splits text into word groups. Glue words attach to following words
    /// only if the combined chunk stays within `maxChunkLength`.
    static func chunks(from text: String) -> [String] {
        let words = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        var result: [String] = []
        var i = 0

        while i < words.count {
            var group = words[i]
            i += 1

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
            }

            // Try to attach exactly one non-glue word
            if i < words.count {
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

    // MARK: - Reading speed

    enum ReadingSpeed: String, CaseIterable, Identifiable {
        case slow = "Slow"
        case medium = "Medium"
        case fast = "Fast"

        var id: String { rawValue }

        /// Milliseconds per character
        var msPerChar: Double {
            switch self {
            case .slow:   return 100
            case .medium: return 80
            case .fast:   return 50
            }
        }
    }

    // MARK: - Display duration

    static func duration(for chunk: String, speed: ReadingSpeed) -> TimeInterval {
        let baseMs = speed.msPerChar * Double(chunk.count)
        let clampedMs = max(400.0, min(1500.0, baseMs))
        return clampedMs / 1000.0
    }

    /// Duration of the blank gap shown between chunks (seconds).
    static func gapDuration(speed: ReadingSpeed) -> TimeInterval {
        switch speed {
        case .slow:   return 0.12
        case .medium: return 0.08
        case .fast:   return 0.05
        }
    }
}
