import Foundation

extension String {
    /// Counts whitespace-separated, non-empty tokens in the string.
    /// Splits on any whitespace character (spaces, tabs) and on newlines.
    var wordCount: Int {
        self.split { $0.isWhitespace || $0.isNewline }
            .filter { !$0.isEmpty }
            .count
    }

    /// Returns the substring containing only the first `n` whitespace-separated
    /// words. Preserves original whitespace between kept words; drops everything
    /// that follows the end of the n-th word. Returns `self` unchanged if `n`
    /// is greater than or equal to the current word count.
    func trimmedToFirstWords(_ n: Int) -> String {
        guard n > 0 else { return "" }
        var kept = 0
        var inWord = false
        for idx in self.indices {
            let isSep = self[idx].isWhitespace || self[idx].isNewline
            if isSep {
                if inWord {
                    inWord = false
                    if kept >= n {
                        return String(self[..<idx])
                    }
                }
            } else if !inWord {
                inWord = true
                kept += 1
            }
        }
        return self
    }
}
