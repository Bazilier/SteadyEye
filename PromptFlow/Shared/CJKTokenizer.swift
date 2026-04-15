import Foundation

nonisolated enum CJKTokenizer {

    /// Detect if text contains CJK characters
    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||  // CJK Unified Ideographs
            (0x3040...0x309F).contains(scalar.value) ||  // Hiragana
            (0x30A0...0x30FF).contains(scalar.value) ||  // Katakana
            (0xAC00...0xD7AF).contains(scalar.value) ||  // Hangul
            (0x3400...0x4DBF).contains(scalar.value)     // CJK Extension A
        }
    }

    /// Detect specific CJK language: "ja", "ko", "zh", or nil
    static func detectLanguage(_ text: String) -> String? {
        let hasKana = text.unicodeScalars.contains {
            (0x3040...0x309F).contains($0.value) || (0x30A0...0x30FF).contains($0.value)
        }
        if hasKana { return "ja" }

        let hasHangul = text.unicodeScalars.contains {
            (0xAC00...0xD7AF).contains($0.value)
        }
        if hasHangul { return "ko" }

        let hasCJK = text.unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value)
        }
        if hasCJK { return "zh" }

        return nil
    }

    /// Tokenize CJK text into words using CFStringTokenizer
    static func tokenize(_ text: String, language: String) -> [String] {
        let cfText = text as CFString
        let range = CFRangeMake(0, CFStringGetLength(cfText))
        let locale = Locale(identifier: language) as CFLocale

        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            cfText,
            range,
            kCFStringTokenizerUnitWord,
            locale
        )

        var tokens: [String] = []
        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)

        while tokenType != [] {
            let tokenRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let start = text.utf16.index(text.utf16.startIndex, offsetBy: tokenRange.location)
            let end = text.utf16.index(start, offsetBy: tokenRange.length)
            if let token = String(text.utf16[start..<end]) {
                tokens.append(token)
            }
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }

        return tokens
    }

    private static let vowels: Set<Character> = [
        "a","e","i","o","u",
        "ā","á","ǎ","à","ē","é","ě","è","ī","í","ǐ","ì","ō","ó","ǒ","ò","ū","ú","ǔ","ù"
    ]

    private static func countVowels(_ roman: String) -> Int {
        roman.lowercased().filter { vowels.contains($0) }.count
    }

    /// Count syllables/morae for timing calculation.
    /// Falls back to per-character romanization if full-string romanization is partial.
    static func countSyllables(_ word: String, language: String) -> Int {
        if language == "ko" {
            let count = word.unicodeScalars.filter { (0xAC00...0xD7AF).contains($0.value) }.count
            return max(1, count)
        }

        // Try full text romanization first
        if let roman = romanize(word, language: language), !roman.isEmpty {
            let count = countVowels(roman)
            if count > 0 { return count }
        }

        // Fallback: romanize character by character
        var total = 0
        for char in word where !char.isPunctuation {
            if let roman = romanize(String(char), language: language), !roman.isEmpty {
                total += max(1, countVowels(roman))
            } else {
                total += 1
            }
        }
        return max(1, total)
    }

    /// Get romanized reading using CFStringTokenizer
    static func romanize(_ word: String, language: String) -> String? {
        let cfText = word as CFString
        let range = CFRangeMake(0, CFStringGetLength(cfText))
        let locale = Locale(identifier: language) as CFLocale

        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            cfText,
            range,
            kCFStringTokenizerUnitWord,
            locale
        )

        CFStringTokenizerAdvanceToNextToken(tokenizer)

        if let latin = CFStringTokenizerCopyCurrentTokenAttribute(
            tokenizer,
            kCFStringTokenizerAttributeLatinTranscription
        ) as? String {
            return latin
        }
        return nil
    }
}
