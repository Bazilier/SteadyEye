import SwiftUI

/// Lays its first subview out alone, or — given a second — splits the bounds
/// into two equal halves on either side of iPhone Duo's crease: side by side
/// when the crease runs top to bottom, stacked when it runs across.
///
/// One layout type for every case on purpose: the subviews keep their
/// identity, and so their state (an open editor sheet, unsaved text), when
/// the device folds, unfolds or turns. Switching between different stacks
/// would rebuild them.
struct CreaseSplitLayout: Layout {
    /// The crease runs top to bottom: halves side by side.
    var sideBySide: Bool
    /// The crease's width, margins included (`DuoDisplayState.creaseFrame`).
    var gap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count > 1 else {
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
            return
        }
        if sideBySide {
            let width = max(0, (bounds.width - gap) / 2)
            let size = ProposedViewSize(width: width, height: bounds.height)
            subviews[0].place(at: bounds.origin, proposal: size)
            subviews[1].place(at: CGPoint(x: bounds.maxX - width, y: bounds.minY), proposal: size)
        } else {
            let height = max(0, (bounds.height - gap) / 2)
            let size = ProposedViewSize(width: bounds.width, height: height)
            subviews[0].place(at: bounds.origin, proposal: size)
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.maxY - height), proposal: size)
        }
    }
}
