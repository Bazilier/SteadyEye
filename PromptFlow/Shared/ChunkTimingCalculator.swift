import Foundation

/// Pure duration calculations — no actor isolation, callable from any context including tests.
enum ChunkTimingCalculator {
    static let pauseMarker = "//"

    /// Maps the 0…1 speed slider to the base per-word duration (ms) used by ORP.
    /// 0.0 → 400ms (slow), 0.5 → ~140ms (normal), 1.0 → 50ms (fast).
    static func orpBaseSpeedMs(sliderValue: Double) -> Int {
        let minMs = 50.0
        let maxMs = 400.0
        let t = 1.0 - sliderValue
        return Int(minMs * pow(maxMs / minMs, t))
    }

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
