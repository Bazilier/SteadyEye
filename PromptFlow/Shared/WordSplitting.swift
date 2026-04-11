import Foundation
import NaturalLanguage

// Tunable: max characters on the right side of the anchor (including the anchor
// letter itself and any trailing "-"). Syllables whose right side exceeds this
// are force-split by `enforceBudget`.
private let rightBudget = 6

// Tunable: minimum clean (non-punctuation, non-hyphen) characters per emitted
// syllable. Splits that would produce shorter fragments are rejected.
private let minSyllableLength = 3

// Vowels recognised by the post-split sanity check (Latin + Cyrillic).
private let vowelSet: Set<Character> = Set("aeiouyAEIOUYаеёиоуыэюяАЕЁИОУЫЭЮЯ")

private func hasVowel(_ s: String) -> Bool {
    s.contains { vowelSet.contains($0) }
}

/// Hyphenation points for a word using Apple's CFStringGetHyphenationLocationBeforeIndex.
/// Returns sorted indices where the word can be broken (ascending).
func hyphenationPoints(for word: String, locale: Locale) -> [Int] {
    let cfWord = word as CFString
    let length = CFStringGetLength(cfWord)
    guard length > 0 else { return [] }

    var points: [Int] = []
    var index = length

    while index > 0 {
        var character: UTF32Char = 0
        let location = CFStringGetHyphenationLocationBeforeIndex(
            cfWord, index, CFRangeMake(0, length),
            0, locale as CFLocale, &character
        )
        if location == kCFNotFound || location <= 0 { break }
        if !points.contains(Int(location)) {
            points.insert(Int(location), at: 0)
        }
        index = location
    }
    return points
}

/// Detects the dominant language of a word and maps it to a Locale whose
/// hyphenation dictionary Apple actually ships.
private func detectLocale(for word: String) -> Locale? {
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(word)
    guard let language = recognizer.dominantLanguage else { return nil }

    let identifier: String
    switch language {
    case .english:    identifier = "en_US"
    case .russian:    identifier = "ru_RU"
    case .german:     identifier = "de_DE"
    case .french:     identifier = "fr_FR"
    case .spanish:    identifier = "es_ES"
    case .italian:    identifier = "it_IT"
    case .portuguese: identifier = "pt_PT"
    case .dutch:      identifier = "nl_NL"
    default:          return nil
    }
    return Locale(identifier: identifier)
}

/// Force-splits a syllable when the chars from its anchor letter to its end
/// (inclusive of trailing "-") exceed `rightBudget`. Validates that emitted
/// parts are at least `minSyllableLength` clean chars and contain a vowel;
/// returns the syllable as-is when no good split exists.
func enforceBudget(_ syllable: String, rightBudget: Int) -> [String] {
    let anchorIdx = orpIndex(for: syllable)
    let suffixLen = syllable.count - anchorIdx  // anchor letter + tail incl. "-"

    if suffixLen <= rightBudget {
        return [syllable]
    }

    let trailingTrim = CharacterSet(charactersIn: "-,.!?;:")
    let cleanLen = syllable.trimmingCharacters(in: trailingTrim).count
    let needsHyphen = syllable.hasSuffix("-")

    var cutPoint = anchorIdx + rightBudget - 1

    // Shift left if the rest would be too short
    while cutPoint > minSyllableLength && (cleanLen - cutPoint) < minSyllableLength {
        cutPoint -= 1
    }
    // Shift right if the first part would be too short
    while cutPoint < minSyllableLength && cutPoint < cleanLen - minSyllableLength {
        cutPoint += 1
    }

    // Bail out if we still can't satisfy length constraints
    if cutPoint < minSyllableLength || (cleanLen - cutPoint) < minSyllableLength {
        return [syllable]
    }
    guard cutPoint < syllable.count, cutPoint > 0 else {
        return [syllable]
    }

    // Vowel check: both parts must contain at least one vowel.
    // If the chosen cut point fails, try ±1, ±2 shifts that still respect length.
    let chars = Array(syllable)
    func partsHaveVowels(_ cp: Int) -> Bool {
        guard cp >= minSyllableLength,
              cp <= cleanLen - minSyllableLength,
              cp > 0, cp < syllable.count else { return false }
        let first = String(chars[0..<cp])
        let restRaw = String(chars[cp...])
        let rest = restRaw.trimmingCharacters(in: trailingTrim)
        return hasVowel(first) && hasVowel(rest)
    }

    var finalCut = cutPoint
    if !partsHaveVowels(finalCut) {
        let candidates = [cutPoint - 1, cutPoint + 1, cutPoint - 2, cutPoint + 2]
        if let alt = candidates.first(where: partsHaveVowels) {
            finalCut = alt
        } else {
            return [syllable]
        }
    }

    let firstIdx = syllable.index(syllable.startIndex, offsetBy: finalCut)
    let firstPart = String(syllable[..<firstIdx]) + "-"
    let restPart = String(syllable[firstIdx...])

    let cleanRest = restPart.hasSuffix("-") ? String(restPart.dropLast()) : restPart
    let finalRest = needsHyphen ? cleanRest + "-" : cleanRest

    // Recursively check the rest in case it's still too long.
    return [firstPart] + enforceBudget(finalRest, rightBudget: rightBudget)
}

/// Merges any tail syllable shorter than `minSyllableLength` clean characters
/// into the previous syllable. Repeats in case the merge produces a new short
/// tail. Single-element inputs are returned unchanged.
func mergeShortTail(_ syllables: [String]) -> [String] {
    guard syllables.count >= 2 else { return syllables }
    let trailingTrim = CharacterSet(charactersIn: "-,.!?;:")
    var result = syllables

    while result.count >= 2 {
        let last = result[result.count - 1]
        let lastClean = last.trimmingCharacters(in: trailingTrim)
        if lastClean.count >= minSyllableLength { break }

        let prev = result[result.count - 2]
        // Strip trailing continuation hyphen from prev before merging.
        let prevClean = prev.hasSuffix("-") ? String(prev.dropLast()) : prev
        let merged = prevClean + last
        result.removeLast(2)
        result.append(merged)
    }
    return result
}

/// Fallback: split a word into fixed-length chunks of approximately `threshold - 1`
/// characters with trailing hyphens on all but the last chunk.
private func fixedLengthSplit(_ word: String, threshold: Int) -> [String] {
    var result: [String] = []
    let chunkSize = max(1, threshold - 1)
    var idx = word.startIndex
    while idx < word.endIndex {
        let end = word.index(idx, offsetBy: chunkSize, limitedBy: word.endIndex) ?? word.endIndex
        let part = String(word[idx..<end])
        let isLast = (end == word.endIndex)
        result.append(isLast ? part : part + "-")
        idx = end
    }
    return result
}

/// Splits a long word into syllables using hyphenation, adding a trailing "-"
/// to continuation syllables. Words containing "-" are first split on the hyphen
/// and each segment is recursively split.
///
/// Locale handling: per-word language is detected via NLLanguageRecognizer.
/// The passed-in `locale` is used as a fallback when detection fails.
/// If hyphenation returns no points, falls back to fixed-length splitting.
func splitLongWord(_ word: String, threshold: Int, locale: Locale?) -> [String] {
    // 1. Split on existing hyphens first, recurse on each segment.
    if word.contains("-") {
        let parts = word.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        var result: [String] = []
        for (i, part) in parts.enumerated() {
            let isLastPart = (i == parts.count - 1)
            // Skip further hyphenation on parts that are already short enough.
            let subParts: [String]
            if part.count <= 8 {
                subParts = [part]
            } else {
                subParts = splitLongWord(part, threshold: threshold, locale: locale)
            }
            for (j, sub) in subParts.enumerated() {
                let isLastSub = (j == subParts.count - 1)
                // Only the last sub of a non-last part needs an extra hyphen
                // (inner splits already add hyphens to their non-last subs).
                if isLastSub && !isLastPart {
                    result.append(sub + "-")
                } else {
                    result.append(sub)
                }
            }
        }
        return mergeShortTail(result)
    }

    // 2. Short enough → no split.
    if word.count <= threshold { return [word] }

    // 3. Detect per-word locale; fall back to passed-in locale.
    let fallbackLocale = locale
    let effectiveLocale = detectLocale(for: word) ?? fallbackLocale

    // 4. No locale at all → fixed-length split.
    guard let effectiveLocale = effectiveLocale else {
        return mergeShortTail(fixedLengthSplit(word, threshold: threshold))
    }

    // 5. Try hyphenation.
    let points = hyphenationPoints(for: word, locale: effectiveLocale)
    if points.isEmpty {
        return mergeShortTail(fixedLengthSplit(word, threshold: threshold))
    }

    // 6. Group syllables into chunks ≤ threshold.
    var groups: [String] = []
    var currentStart = 0
    var lastValidEnd = 0

    for point in points + [word.count] {
        let candidateLength = point - currentStart
        if candidateLength > threshold && lastValidEnd > currentStart {
            let start = word.index(word.startIndex, offsetBy: currentStart)
            let end = word.index(word.startIndex, offsetBy: lastValidEnd)
            groups.append(String(word[start..<end]))
            currentStart = lastValidEnd
        }
        lastValidEnd = point
    }
    if currentStart < word.count {
        let start = word.index(word.startIndex, offsetBy: currentStart)
        groups.append(String(word[start...]))
    }

    // 7. Safety net: if any group is still > threshold (hyphenation too coarse),
    // fall back to fixed-length splitting for the whole word.
    if groups.contains(where: { $0.count > threshold }) {
        return mergeShortTail(fixedLengthSplit(word, threshold: threshold))
    }

    // 8. Add trailing hyphens to all but the last group.
    let withHyphens = groups.enumerated().map { i, g in
        i < groups.count - 1 ? g + "-" : g
    }
    return mergeShortTail(withHyphens)
}
