import Foundation

/// Protocol for language-specific chunking and timing behavior.
/// All methods are pure functions — no UI, no actor isolation.
protocol LanguageStrategy: Sendable {
    /// Split text into chunks for word-by-word display
    func chunks(from text: String) -> [String]

    /// Calculate display duration for a chunk
    func duration(for chunk: String, msPerChar: Double) -> TimeInterval

    /// Check if chunk ends a sentence (for extra pause)
    func endsSentence(_ chunk: String) -> Bool

    /// Check if chunk is an abbreviation needing longer display
    func isAbbreviation(_ chunk: String) -> Bool

    /// Extra pause added after sentence-ending chunks
    var sentencePauseDuration: TimeInterval { get }

    /// Minimum display duration for any chunk
    var minimumDuration: TimeInterval { get }

    /// Whether this language supports ORP (Optimal Recognition Point) alignment
    var supportsORP: Bool { get }

    /// Strict one-word-per-chunk chunker for ORP mode.
    /// Returns chunks where each entry is either a single word (with any attached
    /// punctuation) or an empty string representing a pause marker.
    func chunksPerWord(text: String, baseSpeedMs: Int) -> [String]

    /// Per-word duration for ORP mode. Empty string = pause chunk.
    func durationPerWord(chunk: String, baseSpeedMs: Int) -> TimeInterval
}

extension LanguageStrategy {
    var sentencePauseDuration: TimeInterval { 0.3 }
    var minimumDuration: TimeInterval { 0.3 }

    // Default: non-ORP strategies return empty / zero — they're never called.
    func chunksPerWord(text: String, baseSpeedMs: Int) -> [String] { [] }
    func durationPerWord(chunk: String, baseSpeedMs: Int) -> TimeInterval { 0.3 }
}
