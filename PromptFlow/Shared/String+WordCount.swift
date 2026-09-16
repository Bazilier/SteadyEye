import Foundation

extension String {
    /// Counts whitespace-separated, non-empty tokens in the string.
    /// Splits on any whitespace character (spaces, tabs) and on newlines.
    var wordCount: Int {
        self.split { $0.isWhitespace || $0.isNewline }
            .filter { !$0.isEmpty }
            .count
    }
}
