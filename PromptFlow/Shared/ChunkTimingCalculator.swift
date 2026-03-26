import Foundation

/// Pure duration calculations — no actor isolation, callable from any context including tests.
enum ChunkTimingCalculator {
    static let pauseMarker = "//"

    static func isPause(_ chunk: String) -> Bool {
        let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "//" || trimmed == "／／"
    }

    static func calculateDuration(
        for chunk: String,
        sliderValue: Double,
        strategy: (any LanguageStrategy)? = nil
    ) -> TimeInterval {
        if isPause(chunk) {
            return sliderValue > 0.85 ? 0.2 : 0.5
        }

        let strat = strategy ?? LanguageDetector.detect(chunk)
        let msPerChar = WordChunkEngine.msPerChar(forSlider: sliderValue)
        var d = strat.duration(for: chunk, msPerChar: msPerChar)

        let minDuration: TimeInterval
        if sliderValue > 0.95 { minDuration = 0.1 }
        else if sliderValue > 0.85 { minDuration = 0.15 }
        else { minDuration = strat.minimumDuration }
        d = max(minDuration, min(3.0, d))

        if strat.endsSentence(chunk) {
            d += sliderValue > 0.85 ? 0.1 : strat.sentencePauseDuration
        }

        return d
    }
}
