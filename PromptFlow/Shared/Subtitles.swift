import Foundation

/// A word said in a take, in seconds of the recording's file. Kept in file
/// time, like `Recording.sectionCuts`, so one set serves the whole take
/// and its cut. Enough for an `.srt` too, should one be wanted.
nonisolated struct TimedWord: Codable, Equatable, Sendable {
    var text: String
    var start: Double
    var end: Double
}

/// One on-screen caption: a few words, on the timeline that plays.
nonisolated struct SubtitlePhrase: Equatable, Sendable {
    var text: String
    var start: Double
    var end: Double
}

/// Speech gives the timing, the script the spelling: recognized words are
/// matched to the script's words in order, and a matched word is shown as
/// the script writes it (case, punctuation, names). Words said but not in
/// the script stay as heard; script words not said are left out.
nonisolated enum SubtitleAligner {

    /// The script's words as the reader sees them, the markers taken out.
    static func scriptWords(_ script: String) -> [String] {
        script
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty && !isMarker($0) }
    }

    private static func isMarker(_ token: String) -> Bool {
        if token.allSatisfy({ $0 == "/" || $0 == "／" }) { return true }
        return token.hasPrefix("{") && token.hasSuffix("}")
    }

    /// Lower case, no accents, letters and digits only: what two spellings
    /// of the same word have in common.
    static func normalize(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    static func align(heard: [TimedWord], script: [String]) -> [TimedWord] {
        guard !heard.isEmpty, !script.isEmpty else { return heard }
        let a = heard.map { normalize($0.text) }
        let b = script.map { normalize($0) }
        let n = a.count, m = b.count
        let width = m + 1
        // Best score so far, and the move that reached each cell
        // (0 match, 1 skip a heard word, 2 skip a script word).
        var score = [Int32](repeating: 0, count: (n + 1) * width)
        var move = [UInt8](repeating: 0, count: (n + 1) * width)
        for i in 0...n { move[i * width] = 1 }
        for j in 0...m { move[j] = 2 }
        for i in 1...n {
            for j in 1...m {
                let gain = matchScore(a[i - 1], b[j - 1])
                let diagonal = gain > 0 ? score[(i - 1) * width + j - 1] + gain : Int32.min
                let up = score[(i - 1) * width + j]
                let left = score[i * width + j - 1]
                let index = i * width + j
                if diagonal >= up, diagonal >= left {
                    score[index] = diagonal; move[index] = 0
                } else if up >= left {
                    score[index] = up; move[index] = 1
                } else {
                    score[index] = left; move[index] = 2
                }
            }
        }

        // The matched pairs, in order.
        var pairs: [(heard: Int, script: Int)] = []
        var i = n, j = m
        while i > 0, j > 0 {
            switch move[i * width + j] {
            case 0:
                pairs.append((i - 1, j - 1))
                i -= 1; j -= 1
            case 1:
                i -= 1
            default:
                j -= 1
            }
        }
        pairs.reverse()

        // Matched words take the script's spelling; between two matches, a
        // short stretch heard and a short stretch of script of about the
        // same length are the same words misheard ("and study I" for "in
        // SteadyEye"), so the script's words take that stretch's time.
        var out: [TimedWord] = []
        var nextHeard = 0, nextScript = 0
        func fillGap(heardEnd: Int, scriptEnd: Int) {
            let heardGap = Array(heard[nextHeard..<heardEnd])
            let scriptGap = Array(script[nextScript..<scriptEnd])
            if let replaced = substitute(heardGap, with: scriptGap) {
                out += replaced
            } else {
                out += heardGap
            }
        }
        for pair in pairs {
            fillGap(heardEnd: pair.heard, scriptEnd: pair.script)
            var word = heard[pair.heard]
            word.text = script[pair.script]
            out.append(word)
            nextHeard = pair.heard + 1
            nextScript = pair.script + 1
        }
        fillGap(heardEnd: n, scriptEnd: m)
        return out
    }

    /// Up to this many words either side count as one misheard stretch.
    static let maxSubstitutionWords = 4
    /// Recognizers write numbers and times as digits ("двадцать часов"
    /// heard as "20:00"): a heard stretch with digits stands for up to this
    /// many script words, whatever their length.
    static let maxNumberWords = 6

    private static func substitute(_ heard: [TimedWord], with script: [String]) -> [TimedWord]? {
        let hasDigits = heard.contains { $0.text.contains(where: \.isNumber) }
        guard !heard.isEmpty, !script.isEmpty,
              heard.count <= maxSubstitutionWords,
              script.count <= (hasDigits ? maxNumberWords : maxSubstitutionWords),
              let first = heard.first, let last = heard.last
        else { return nil }
        let heardLength = Double(heard.reduce(0) { $0 + normalize($1.text).count })
        let scriptLength = Double(script.reduce(0) { $0 + normalize($1).count })
        guard heardLength > 0, scriptLength > 0,
              hasDigits || (0.5...2).contains(scriptLength / heardLength)
        else { return nil }
        let span = last.end - first.start
        var cursor = first.start
        return script.map { word in
            let share = span * Double(max(1, normalize(word).count)) / scriptLength
            defer { cursor += share }
            return TimedWord(text: word, start: cursor, end: cursor + share)
        }
    }

    /// 2 for the same word, 1 for a near miss (a recognizer's slip on a
    /// longer word), 0 otherwise.
    private static func matchScore(_ x: String, _ y: String) -> Int32 {
        if x.isEmpty || y.isEmpty { return 0 }
        if x == y { return 2 }
        guard min(x.count, y.count) >= 4 else { return 0 }
        let distance = levenshtein(Array(x), Array(y))
        return Double(distance) / Double(max(x.count, y.count)) <= 0.25 ? 1 : 0
    }

    private static func levenshtein(_ x: [Character], _ y: [Character]) -> Int {
        var previous = Array(0...y.count)
        for (i, cx) in x.enumerated() {
            var current = [i + 1]
            for (j, cy) in y.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (cx == cy ? 0 : 1)))
            }
            previous = current
        }
        return previous[y.count]
    }
}

/// Words into reels-style captions: a few words at a time, broken at
/// sentence ends, pauses and the joints of a cut.
nonisolated enum SubtitlePhrases {
    static let maxWords = 5
    static let maxCharacters = 28
    /// A silence longer than this starts a new caption.
    static let pauseBreakSec: Double = 0.6
    /// A caption stays at least this long, and a little past its last word.
    static let minDurationSec: Double = 0.5
    static let tailSec: Double = 0.3

    /// Captions on the timeline that plays: the cut's when `keep` is given
    /// (words in the cut-away parts are dropped), the file's otherwise.
    static func phrases(words: [TimedWord], keep: [ClosedRange<Double>]?) -> [SubtitlePhrase] {
        let placed = place(words, keep: keep)
        var phrases: [SubtitlePhrase] = []
        var current: [(word: TimedWord, part: Int)] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            phrases.append(SubtitlePhrase(
                text: current.map(\.word.text).joined(separator: " "),
                start: first.word.start,
                end: last.word.end
            ))
            current.removeAll()
        }

        for item in placed {
            if let last = current.last {
                let text = (current.map(\.word.text) + [item.word.text]).joined(separator: " ")
                let breaks = item.part != last.part
                    || item.word.start - last.word.end > pauseBreakSec
                    || endsSentence(last.word.text)
                    || current.count >= maxWords
                    || text.count > maxCharacters
                if breaks { flush() }
            }
            current.append(item)
        }
        flush()

        // Hold each caption a little, never into the next one.
        for index in phrases.indices {
            let next = index + 1 < phrases.count ? phrases[index + 1].start : .infinity
            let wanted = max(phrases[index].end + tailSec, phrases[index].start + minDurationSec)
            phrases[index].end = min(wanted, next)
        }
        return phrases
    }

    /// Each word on the playing timeline, with the kept part it falls in
    /// (a caption never spans a joint).
    private static func place(_ words: [TimedWord], keep: [ClosedRange<Double>]?) -> [(word: TimedWord, part: Int)] {
        guard let keep else { return words.map { ($0, 0) } }
        let parts = keep.sorted { $0.lowerBound < $1.lowerBound }
        var offsets: [Double] = []
        var total = 0.0
        for part in parts {
            offsets.append(total)
            total += part.upperBound - part.lowerBound
        }
        return words.compactMap { word in
            let middle = (word.start + word.end) / 2
            guard let index = parts.firstIndex(where: { $0.contains(middle) }) else { return nil }
            let part = parts[index]
            var placed = word
            placed.start = offsets[index] + max(word.start, part.lowerBound) - part.lowerBound
            placed.end = offsets[index] + min(word.end, part.upperBound) - part.lowerBound
            return (placed, index)
        }
    }

    private static func endsSentence(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return ".!?…。！？".contains(last)
    }

    /// The caption showing at `time`, if any.
    static func phrase(at time: Double, in phrases: [SubtitlePhrase]) -> SubtitlePhrase? {
        var low = 0, high = phrases.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if phrases[mid].end <= time {
                low = mid + 1
            } else if phrases[mid].start > time {
                high = mid - 1
            } else {
                return phrases[mid]
            }
        }
        return nil
    }
}
