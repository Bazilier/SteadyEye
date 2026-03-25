import Foundation

/// Detects the dominant language of text and returns the appropriate strategy.
enum LanguageDetector {
    static func detect(_ text: String) -> LanguageStrategy {
        // CJK (most specific — check first)
        if CJKTokenizer.containsCJK(text) {
            let lang = CJKTokenizer.detectLanguage(text) ?? "ja"
            return CJKLanguageStrategy(language: lang)
        }

        // Arabic script
        if containsArabic(text) {
            return ArabicLanguageStrategy()
        }

        // Default: Latin/Cyrillic
        return LatinLanguageStrategy()
    }

    private static func containsArabic(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x0600...0x06FF).contains(scalar.value) ||  // Arabic
            (0x0750...0x077F).contains(scalar.value) ||  // Arabic Supplement
            (0xFB50...0xFDFF).contains(scalar.value)     // Arabic Presentation Forms
        }
    }
}
