import SwiftUI

// MARK: - Zoom transition

/// Card-to-cover zoom shared by the script list and the recordings grid.
extension View {
    /// iOS 18+: the card the cover zooms out of, clipped to the card shape.
    @ViewBuilder
    func cardZoomSource(id: UUID, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            matchedTransitionSource(id: id, in: namespace) { source in
                source.clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            }
        } else {
            self
        }
    }

    /// iOS 18+: the cover zooms in from its card; iOS 17 keeps the default
    /// full-screen cover transition.
    @ViewBuilder
    func cardZoomTransition(id: UUID, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }
}
