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
        // Ramp for pauses and minimum duration: 0 at slider ≤ 0.5 (unchanged
        // slow-half behavior), 1 at slider 1.0. Continuous so there is no
        // speed cliff anywhere on the slider.
        let t = min(1.0, max(0.0, (sliderValue - 0.5) / 0.5))

        if isPause(chunk) {
            return expLerp(0.5, 0.2, t)
        }

        let strat = strategy ?? LanguageDetector.detect(chunk)
        let msPerChar = WordChunkEngine.msPerChar(forSlider: sliderValue)
        var d = strat.duration(for: chunk, msPerChar: msPerChar)

        let minDuration = rampDown(strat.minimumDuration, to: 0.1, t)
        d = max(minDuration, min(3.0, d))

        if strat.endsSentence(chunk) {
            d += rampDown(strat.sentencePauseDuration, to: 0.1, t)
        }

        return d
    }

    /// Exponential interpolation from `a` (t = 0) to `b` (t = 1).
    private static func expLerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a * pow(b / a, t)
    }

    /// `expLerp` toward `floor`, but never ramps a value that is already at or
    /// below `floor` upward.
    private static func rampDown(_ value: Double, to floor: Double, _ t: Double) -> Double {
        value <= floor ? value : expLerp(value, floor, t)
    }
}
