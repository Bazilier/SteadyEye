import SwiftUI

/// Press feedback for the script and recording cards. The card eases down
/// while touched and stays down, via `opener`, until its destination has
/// covered it, so a zoom starts from the pressed size; it is back at full
/// size, without animation, before the destination is dismissed.
struct CardPressStyle: ButtonStyle {
    static let pressedScale: CGFloat = 0.96
    static let pressDuration: Double = 0.3
    /// Back to full size after a cancelled press.
    static let releaseDuration: Double = 0.2

    let id: UUID
    let opener: CardOpener
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let isDown = !reduceMotion && (configuration.isPressed || opener.openingID == id)
        configuration.label
            .scaleEffect(isDown ? Self.pressedScale : 1)
            .animation(
                .easeOut(duration: isDown ? Self.pressDuration : Self.releaseDuration),
                value: isDown
            )
            .onChange(of: configuration.isPressed) { _, isPressed in
                opener.pressChanged(isPressed)
            }
    }
}

/// Opens a pressed card's destination once its shrink has finished:
/// `pressDuration` counted from touch-down, so a quick tap waits for the
/// rest of it and a long press opens at once. One card at a time.
@MainActor @Observable
final class CardOpener {
    /// The card held at the pressed size: waiting to open, or opening.
    private(set) var openingID: UUID?
    /// The card waiting to open; other cards, its edit button and its
    /// context menu are disabled meanwhile.
    private(set) var pendingID: UUID?

    @ObservationIgnored private var pressStart: Date?
    @ObservationIgnored private var pending: Task<Void, Never>?

    fileprivate func pressChanged(_ isPressed: Bool) {
        if isPressed {
            pressStart = .now
        } else {
            // Cleared after the button's action has read it.
            DispatchQueue.main.async { self.pressStart = nil }
        }
    }

    func open(_ id: UUID, reduceMotion: Bool, perform: @escaping () -> Void) {
        guard pendingID == nil else { return }
        if reduceMotion {
            perform()
            return
        }
        openingID = id
        pendingID = id
        // No recorded touch-down (a tap too quick for `isPressed`, or
        // VoiceOver): the shrink starts now.
        let elapsed = pressStart.map { Date.now.timeIntervalSince($0) } ?? 0
        let wait = max(0, CardPressStyle.pressDuration - elapsed)
        pending = Task {
            if wait > 0 {
                try? await Task.sleep(for: .seconds(wait))
            }
            guard !Task.isCancelled else { return }
            pending = nil
            pendingID = nil
            perform()
        }
    }

    /// Drops a pending open (scroll, view gone) and lets the card ease
    /// back. No effect once the destination has opened.
    func cancelPending() {
        guard pendingID != nil else { return }
        pending?.cancel()
        pending = nil
        pendingID = nil
        openingID = nil
    }

    /// The destination now covers the card, or is closing before it got
    /// there: back to full size at once, so the list is uncovered with a
    /// full-size card and the dismiss lands on it.
    func resetCard() {
        guard openingID != nil else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { openingID = nil }
    }
}

extension View {
    /// Runs `action` once the view's presentation has finished (UIKit
    /// `viewDidAppear`), not when it is inserted like `onAppear`.
    func onPresentationComplete(_ action: @escaping () -> Void) -> some View {
        background(PresentationCompleteProbe(action: action).frame(width: 0, height: 0))
    }

    /// Cancels a pending card open as soon as the list starts scrolling
    /// (iOS 18+; on iOS 17 the wait is short enough to let it run).
    @ViewBuilder
    func cancelsPendingCardOpen(_ opener: CardOpener) -> some View {
        if #available(iOS 18.0, *) {
            onScrollPhaseChange { _, phase in
                if phase != .idle { opener.cancelPending() }
            }
        } else {
            self
        }
    }
}

private struct PresentationCompleteProbe: UIViewControllerRepresentable {
    let action: () -> Void

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.action = action
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.action = action
    }

    final class Controller: UIViewController {
        var action: (() -> Void)?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            action?()
        }
    }
}
