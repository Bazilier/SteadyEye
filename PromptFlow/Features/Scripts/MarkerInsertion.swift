import Foundation

/// The three slash markers the prompter reads, and how the editor puts one
/// into the text.
enum ScriptMarker: String, CaseIterable, Identifiable {
    /// `//`: a short pause.
    case shortPause = "//"
    /// `///`: a second of silence (`MarkerPreprocessor.longPauseSec`).
    case longPause = "///"
    /// `////`: a section break — the prompter holds for Repeat or Next.
    case section = "////"

    var id: String { rawValue }
}

enum MarkerInsertion {
    /// `text` with `marker` in place of `range`, and the cursor position
    /// right after it. A pause gets a space on each side unless whitespace
    /// is already there; a section break gets a line of its own.
    static func insert(
        _ marker: ScriptMarker,
        into text: String,
        replacing range: Range<String.Index>
    ) -> (text: String, cursor: String.Index) {
        let before = text[..<range.lowerBound]
        let after = text[range.upperBound...]
        let separator: Character = marker == .section ? "\n" : " "
        let isSeparator: (Character) -> Bool = marker == .section
            ? { $0.isNewline }
            : { $0.isWhitespace }

        var inserted = marker.rawValue
        if let last = before.last, !isSeparator(last) { inserted.insert(separator, at: inserted.startIndex) }
        if let first = after.first {
            if !isSeparator(first) { inserted.append(separator) }
        } else if marker == .section {
            inserted.append(separator)
        }

        let result = before + inserted + after
        let cursor = result.index(result.startIndex, offsetBy: before.count + inserted.count)
        return (String(result), cursor)
    }
}
