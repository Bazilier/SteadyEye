import Foundation

/// Detects the dominant language of text and returns the appropriate strategy.
/// Only samples the first 200 characters for performance.
enum LanguageDetector {
    static func detect(_ text: String) -> LanguageStrategy {
        let sample = String(text.prefix(200))

        if CJKTokenizer.containsCJK(sample) {
            let lang = CJKTokenizer.detectLanguage(sample) ?? "ja"
            return CJKLanguageStrategy(language: lang)
        }

        if containsArabic(sample) {
            return ArabicLanguageStrategy()
        }

        return LatinLanguageStrategy()
    }

    private static func containsArabic(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x0600...0x06FF).contains(scalar.value) ||
            (0x0750...0x077F).contains(scalar.value) ||
            (0xFB50...0xFDFF).contains(scalar.value)
        }
    }
}
