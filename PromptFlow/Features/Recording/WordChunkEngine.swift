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
    /// Exponential mapping — extreme positions feel dramatically different.
    /// 0.0 → 120ms (very slow), 0.5 → ~11ms (normal), 1.0 → 1ms (instant)
    static func msPerChar(forSlider value: Double) -> Double {
        let minMs = 1.0
        let maxMs = 120.0
        let t = 1.0 - value
        return minMs * pow(maxMs / minMs, t)
    }

    /// Base duration for a chunk given character count and slider value.
    /// Minimum clamping is handled by ChunkPlayerEngine.calculateDuration().
    static func duration(for chunk: String, sliderValue: Double) -> TimeInterval {
        let ms = msPerChar(forSlider: sliderValue) * Double(chunk.count)
        return min(3.0, ms / 1000.0)
    }

    /// Duration of the blank gap shown between chunks.
    static func gapDuration(sliderValue: Double) -> TimeInterval {
        let gap = 0.15 - 0.12 * sliderValue
        return max(0.02, gap)
    }
}
