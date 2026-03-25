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
}

extension LanguageStrategy {
    var sentencePauseDuration: TimeInterval { 0.3 }
    var minimumDuration: TimeInterval { 0.3 }
}
