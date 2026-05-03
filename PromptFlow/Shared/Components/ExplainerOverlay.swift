import SwiftUI
import UIKit

/// Modal first-run / educational card on top of a dimmed scrim. Single
/// dismiss button — the scrim itself is intentionally tap-blocked so
/// users actually read the copy before proceeding.
///
/// Used by:
/// - `BulkImportView` (icon `doc.on.doc`) — first-run bulk-import tour
/// - `ScriptEditorView` (icon `lightbulb`) — first-run editor tip
/// - `RecordingView` (icon `hand.point.up.left`) — first-run drag-to-position tip
///
/// Layout was extracted verbatim from the original BulkImportView
/// inline overlay, with one addition: the card has a `maxWidth: 400`
/// cap so it doesn't span the full width of an iPad display.
///
/// **Naming note:** the spec API used `body: LocalizedStringKey` for
/// the message text, but `body` collides with SwiftUI's required
/// `var body: some View`. Renamed to `message` — same convention as
/// `Alert(title:message:)`.
///
/// Animation: the root `ZStack` carries `.transition(.opacity)`, so a
/// caller that wants animated show/hide can add
/// `.animation(.easeInOut(duration: 0.2), value: <flag>)` on its parent.
struct ExplainerOverlay: View {
    /// Two-way binding. Caller flips to true to present; the component
    /// flips to false on the primary button tap (after invoking
    /// `onDismiss`). Drives the parent's `if showFoo { ... }` gate.
    @Binding var isPresented: Bool

    /// SF Symbol name for the hero glyph. Rendered at 56pt, light
    /// weight, orange tint.
    let icon: String

    /// Localized title — `.title2.bold()`, centered.
    let title: LocalizedStringKey

    /// Localized body text — `.body`, secondary color, centered, with
    /// `.fixedSize(horizontal: false, vertical: true)` so multi-line
    /// content never truncates inside the card.
    let message: LocalizedStringKey

    /// Localized primary-button label — `.body.weight(.semibold)`.
    let buttonLabel: LocalizedStringKey

    /// Side-effect closure invoked on the primary-button tap.
    /// **Dismiss contract:** `onDismiss()` runs FIRST, THEN the
    /// component flips `isPresented = false`. This lets a caller's
    /// `hasSeen…` flag flip commit before the overlay unmounts.
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                // Scrim taps are intentionally no-op — only the button
                // dismisses, so users actually read the copy.
                .onTapGesture {}

            VStack(spacing: 20) {
                Image(systemName: icon)
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.orange)

                Text(title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    onDismiss()
                    isPresented = false
                } label: {
                    Text(buttonLabel)
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .padding(.top, 4)
            }
            .padding(28)
            .frame(maxWidth: 400)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .padding(.horizontal, 24)
        }
        .transition(.opacity)
    }
}
