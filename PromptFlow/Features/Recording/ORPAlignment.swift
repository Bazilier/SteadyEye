import SwiftUI
import UIKit

/// Optimal Recognition Point index for a word.
/// Anchor letter index used for horizontal alignment (Spritz-style).
nonisolated func orpIndex(for word: String) -> Int {
    let clean = word.trimmingCharacters(in: .punctuationCharacters)
    let len = clean.count
    switch len {
    case 0...1: return 0
    case 2...5: return 1
    case 6...9: return 2
    case 10...13: return 3
    default: return 4
    }
}

/// Width of a single monospaced character at the given font size.
private func monoCharWidth(fontSize: CGFloat) -> CGFloat {
    let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
    return ("M" as NSString).size(withAttributes: [.font: font]).width
}

/// Renders a word with its ORP anchor letter aligned to the parent's center X.
struct ORPWord: View {
    let word: String
    let fontSize: CGFloat
    let highlightAnchor: Bool
    var anchorColor: Color = .orange
    var textColor: Color = .white

    var body: some View {
        // Empty word: render empty Text
        if word.isEmpty {
            Text("")
                .font(.system(size: fontSize, weight: .medium, design: .monospaced))
        } else if word.count > 16 {
            // Fallback: render centered without ORP alignment
            Text(word)
                .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                .foregroundStyle(textColor)
        } else {
            let idx = min(orpIndex(for: word), max(0, word.count - 1))
            let chars = Array(word)
            let prefix = String(chars[0..<idx])
            let anchor = String(chars[idx])
            let suffix = idx + 1 <= chars.count - 1 ? String(chars[(idx + 1)...]) : ""

            let charWidth = monoCharWidth(fontSize: fontSize)
            let totalWordWidth = CGFloat(word.count) * charWidth
            let offsetX = -(CGFloat(prefix.count) * charWidth + charWidth / 2 - totalWordWidth / 2)

            HStack(spacing: 0) {
                Text(prefix)
                    .foregroundStyle(textColor)
                Text(anchor)
                    .foregroundStyle(highlightAnchor ? anchorColor : textColor)
                Text(suffix)
                    .foregroundStyle(textColor)
            }
            .font(.system(size: fontSize, weight: .medium, design: .monospaced))
            .offset(x: offsetX)
        }
    }
}
