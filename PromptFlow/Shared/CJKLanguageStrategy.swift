import Foundation

// MARK: - Token and Chunk metadata

struct CJKToken: Sendable {
    let text: String
    let syllables: Int
    let visualWeight: Int
    let kanjiCount: Int
    let isParticle: Bool
    let hasSentenceEnd: Bool
}

struct CJKChunk: Sendable {
    var text: String
    var totalSyllables: Int
    var totalWeight: Int
    var kanjiCount: Int
    var endsSentence: Bool
}

// MARK: - Strategy

/// Handles Japanese, Chinese, and Korean text.
struct CJKLanguageStrategy: LanguageStrategy, Sendable {

    let maxChunkWeight = 6
    let language: String
    var supportsORP: Bool { false }

    init(language: String = "ja") {
        self.language = language
    }

    // MARK: - Character classification

    static func isKanji(_ char: Character) -> Bool {
        guard let scalar = char.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(scalar) || (0x3400...0x4DBF).contains(scalar)
    }

    static func visualWeight(_ text: String) -> Int {
        text.reduce(0) { sum, char in
            if char.isPunctuation { return sum }
            return sum + (isKanji(char) ? 2 : 1)
        }
    }

    static func kanjiCount(_ text: String) -> Int {
        text.filter { isKanji($0) }.count
    }

    private static let jaParticles: Set<String> = [
        "は", "が", "を", "に", "で", "と", "も", "の", "へ", "か", "よ", "ね",
        "な", "て", "た", "だ", "ば", "ら", "わ", "さ", "ぞ", "ぜ", "け"
    ]

    private static let cjkPunctuation: Set<Character> = [
        "。", "！", "？", "、", "…", ".", "!", "?",
        "（", "）", "「", "」", "『", "』", "【", "】",
        "〜", "★", "♪", "―", "—"
    ]

    private static let sentenceEnders: Set<Character> = ["。", "！", "？", ".", "!", "?"]

    // MARK: - LanguageStrategy

    func endsSentence(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return Self.sentenceEnders.contains(last)
    }

    func isAbbreviation(_ chunk: String) -> Bool { false }

    /// Duration based on pre-computed syllables and kanji count.
    /// Called by ChunkPlayerEngine with msPerChar from the speed slider.
    func duration(for chunk: String, msPerChar: Double) -> TimeInterval {
        let trimmed = chunk.trimmingCharacters(in: .punctuationCharacters)
        let syllables = CJKTokenizer.countSyllables(trimmed, language: language)
        let kanji = Self.kanjiCount(trimmed)
        // Base: syllables × syllable duration + kanji bonus
        let syllableDuration = Double(syllables) * 0.25
        let kanjiBonus = Double(kanji) * 0.15
        let speedFactor = msPerChar / 30.0  // normalize: 30ms = 1.0× speed
        return (syllableDuration + kanjiBonus) * speedFactor
    }

    // MARK: - Chunking

    func chunks(from text: String) -> [String] {
        // Split on "//" first — extract pause markers before CJK tokenization
        let segments = text.components(separatedBy: "//")
        var allChunks: [String] = []

        for (index, segment) in segments.enumerated() {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                allChunks.append(contentsOf: chunksForSegment(trimmed))
            }
            // Insert pause between segments (not after last)
            if index < segments.count - 1 {
                allChunks.append("//")
            }
        }

        return allChunks
    }

    /// Tokenize and group a single text segment (no "//" inside).
    private func chunksForSegment(_ text: String) -> [String] {
        let rawTokens = CJKTokenizer.tokenize(text, language: language)

        // Step 1: Reattach punctuation
        let tokenStrings = reattachPunctuation(rawTokens: rawTokens, originalText: text)

        // Step 2: Build CJKToken metadata for each token
        let tokens = tokenStrings.map { tokenText -> CJKToken in
            CJKToken(
                text: tokenText,
                syllables: CJKTokenizer.countSyllables(
                    String(tokenText.filter { !$0.isPunctuation }), language: language),
                visualWeight: Self.visualWeight(tokenText),
                kanjiCount: Self.kanjiCount(tokenText),
                isParticle: language == "ja" && Self.jaParticles.contains(tokenText),
                hasSentenceEnd: endsSentence(tokenText)
            )
        }

        // Step 3: Group tokens into chunks
        var chunks: [CJKChunk] = []
        var current = CJKChunk(text: "", totalSyllables: 0, totalWeight: 0, kanjiCount: 0, endsSentence: false)

        for token in tokens {
            // Particle: attach backward to previous chunk
            if token.isParticle {
                // Flush current group
                if !current.text.isEmpty {
                    chunks.append(current)
                    current = CJKChunk(text: "", totalSyllables: 0, totalWeight: 0, kanjiCount: 0, endsSentence: false)
                }
                // Attach to last chunk if weight allows
                if var last = chunks.last, last.text != "//",
                   last.totalWeight + token.visualWeight <= maxChunkWeight {
                    chunks.removeLast()
                    last.text += token.text
                    last.totalSyllables += token.syllables
                    last.totalWeight += token.visualWeight
                    last.kanjiCount += token.kanjiCount
                    last.endsSentence = token.hasSentenceEnd
                    chunks.append(last)
                } else {
                    current = CJKChunk(
                        text: token.text, totalSyllables: token.syllables,
                        totalWeight: token.visualWeight, kanjiCount: token.kanjiCount,
                        endsSentence: token.hasSentenceEnd)
                }
                continue
            }

            // Sentence end on current group: flush
            if current.endsSentence {
                chunks.append(current)
                current = CJKChunk(
                    text: token.text, totalSyllables: token.syllables,
                    totalWeight: token.visualWeight, kanjiCount: token.kanjiCount,
                    endsSentence: token.hasSentenceEnd)
                continue
            }

            // Try to add to current group
            if current.text.isEmpty {
                current = CJKChunk(
                    text: token.text, totalSyllables: token.syllables,
                    totalWeight: token.visualWeight, kanjiCount: token.kanjiCount,
                    endsSentence: token.hasSentenceEnd)
            } else if current.totalWeight + token.visualWeight <= maxChunkWeight {
                current.text += token.text
                current.totalSyllables += token.syllables
                current.totalWeight += token.visualWeight
                current.kanjiCount += token.kanjiCount
                current.endsSentence = token.hasSentenceEnd
            } else {
                chunks.append(current)
                current = CJKChunk(
                    text: token.text, totalSyllables: token.syllables,
                    totalWeight: token.visualWeight, kanjiCount: token.kanjiCount,
                    endsSentence: token.hasSentenceEnd)
            }
        }
        if !current.text.isEmpty { chunks.append(current) }

        return chunks.map { $0.text }
    }

    // MARK: - Punctuation reattachment

    private func reattachPunctuation(rawTokens: [String], originalText text: String) -> [String] {
        var enriched: [String] = []
        var searchStart = text.startIndex

        for token in rawTokens {
            guard let range = text.range(of: token, range: searchStart..<text.endIndex) else {
                enriched.append(token)
                continue
            }

            let gap = text[searchStart..<range.lowerBound]
            if !gap.isEmpty, var last = enriched.last {
                let punct = gap.filter { Self.cjkPunctuation.contains($0) || $0.isPunctuation }
                if !punct.isEmpty {
                    enriched.removeLast()
                    last += punct
                    enriched.append(last)
                }
            }

            enriched.append(token)
            searchStart = range.upperBound
        }

        if searchStart < text.endIndex {
            let trailing = text[searchStart...]
            let punct = trailing.filter { Self.cjkPunctuation.contains($0) || $0.isPunctuation }
            if !punct.isEmpty, var last = enriched.last {
                enriched.removeLast()
                last += punct
                enriched.append(last)
            }
        }

        return enriched
    }
}
