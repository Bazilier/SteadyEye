import Foundation

/// Protocol for language-specific chunking and timing behavior.
/// All methods are pure functions — no UI, no actor isolation.
protocol LanguageStrategy: Sendable {
    /// Split text into chunks for word-by-word display
    nonisolated func chunks(from text: String) -> [String]

    /// Calculate display duration for a chunk
    nonisolated func duration(for chunk: String, msPerChar: Double) -> TimeInterval

    /// Check if chunk ends a sentence (for extra pause)
    nonisolated func endsSentence(_ chunk: String) -> Bool

    /// Check if chunk is an abbreviation needing longer display
    nonisolated func isAbbreviation(_ chunk: String) -> Bool

    /// Extra pause added after sentence-ending chunks
    nonisolated var sentencePauseDuration: TimeInterval { get }

    /// Minimum display duration for any chunk
    nonisolated var minimumDuration: TimeInterval { get }

    /// Whether this language supports ORP (Optimal Recognition Point) alignment
    nonisolated var supportsORP: Bool { get }

    /// Locale used for long-word hyphenation in ORP mode. `nil` = no hyphenation.
    nonisolated var hyphenationLocale: Locale? { get }

    /// Strict one-word-per-chunk chunker for ORP mode.
    /// Returns chunks where each entry is either a single word (with any attached
    /// punctuation) or an empty string representing a pause marker.
    nonisolated func chunksPerWord(text: String, baseSpeedMs: Int) -> [String]

    /// Per-word duration for ORP mode. Empty string = pause chunk.
    nonisolated func durationPerWord(chunk: String, baseSpeedMs: Int) -> TimeInterval
}

extension LanguageStrategy {
    nonisolated var sentencePauseDuration: TimeInterval { 0.3 }
    nonisolated var minimumDuration: TimeInterval { 0.3 }

    // Default: non-ORP strategies return empty / zero — they're never called.
    nonisolated var hyphenationLocale: Locale? { nil }
    nonisolated func chunksPerWord(text: String, baseSpeedMs: Int) -> [String] { [] }
    nonisolated func durationPerWord(chunk: String, baseSpeedMs: Int) -> TimeInterval { 0.3 }
}
