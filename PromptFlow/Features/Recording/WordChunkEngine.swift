import Foundation

/// Thin router — detects language and delegates to the appropriate strategy.
/// Also provides static utility functions used by other modules.
enum WordChunkEngine {

    /// Split text into display chunks using the appropriate language strategy.
    static func chunks(from text: String) -> [String] {
        let strategy = LanguageDetector.detect(text)
        return strategy.chunks(from: text)
    }

    /// Check if a chunk ends with sentence-ending punctuation (any language).
    static func endsSentence(_ chunk: String) -> Bool {
        chunk.hasSuffix(".") || chunk.hasSuffix("!") || chunk.hasSuffix("?") ||
        chunk.hasSuffix("؟") || chunk.hasSuffix("۔") ||
        chunk.hasSuffix("。") || chunk.hasSuffix("！") || chunk.hasSuffix("？")
    }

    // MARK: - Speed / duration utilities (language-independent)

    /// Converts a 0…1 slider value to milliseconds per character.
    /// 0.0 = slowest (80ms), 1.0 = fastest (12ms).
    static func msPerChar(forSlider value: Double) -> Double {
        80.0 * pow(0.15, value)
    }

    /// Base duration for a chunk given character count and slider value.
    /// Used by strategies internally. Clamps to 0.25s–2.0s.
    static func duration(for chunk: String, sliderValue: Double) -> TimeInterval {
        let ms = msPerChar(forSlider: sliderValue) * Double(chunk.count)
        return max(0.25, min(2.0, ms / 1000.0))
    }

    /// Duration of the blank gap shown between chunks.
    static func gapDuration(sliderValue: Double) -> TimeInterval {
        let gap = 0.12 - 0.08 * sliderValue
        return max(0.03, gap)
    }
}
