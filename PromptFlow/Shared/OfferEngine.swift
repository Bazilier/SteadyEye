import Foundation
import SwiftUI

/// Decides which RevenueCat offering to show on each paywall mount,
/// based on user state and active offers.
///
/// Public API is MainActor. State is persisted in UserDefaults under
/// keys defined by each `OfferDefinition`.
@MainActor
final class OfferEngine {
    static let shared = OfferEngine()
    private init() {}

    // MARK: - Public API

    /// Resolves which RevenueCat offering id to use for a paywall mount.
    /// Returns `nil` when the default offering should be used.
    ///
    /// Algorithm:
    /// 1. If user is already Pro, return nil (paywall shouldn't even
    ///    mount, but defensive).
    /// 2. If `discount50AfterFirstDismiss` is active (timer running and
    ///    not used), return its `revenueCatOfferingId`.
    /// 3. Otherwise return nil (default offering).
    ///
    /// Parked 2026-05-03: discount_50 is now the RC Current offering, so
    /// timer-based selection is unused. Always returns nil to delegate
    /// selection to `offerings.current`. The rest of the engine (timer
    /// state, used flags) is left intact in case we revive timer-based
    /// activation for a future winback or re-engagement offer.
    func resolveOfferingId(source: String) -> String? {
        return nil
    }

    /// Called when a paywall is dismissed without purchase. If this is
    /// the user's first dismiss (and the offer hasn't been used), starts
    /// the discount_50 window.
    func paywallDismissedWithoutPurchase(source: String) {
        let offer = OfferDefinition.discount50AfterFirstDismiss

        let startedAt = UserDefaults.standard.double(forKey: offer.startedAtKey)
        let used = UserDefaults.standard.bool(forKey: offer.usedKey)

        // Only start the timer once. Subsequent dismisses during the
        // active window or after the offer has been used are no-ops.
        guard startedAt == 0, !used else { return }

        let now = Date().timeIntervalSince1970
        UserDefaults.standard.set(now, forKey: offer.startedAtKey)

        AppAnalytics.log("offer_started", params: [
            "offer_id": offer.identifier,
            "trigger_source": source,
        ])
    }

    /// Called when user successfully purchases. Marks all currently-active
    /// offers as used so they don't reappear if subscription lapses.
    func purchaseCompleted(source: String, offeringIdPurchasedFrom: String?) {
        let offer = OfferDefinition.discount50AfterFirstDismiss
        if isOfferActive(offer) {
            UserDefaults.standard.set(true, forKey: offer.usedKey)
            AppAnalytics.log("offer_converted", params: [
                "offer_id": offer.identifier,
                "trigger_source": source,
                "offering_id": offeringIdPurchasedFrom ?? "default",
            ])
        }
    }

    /// True if the offer's timer is running and the offer hasn't been
    /// used. Window-expired offers are auto-marked used as a side
    /// effect of this check, so they don't reactivate on next call.
    func isOfferActive(_ offer: OfferDefinition) -> Bool {
        let used = UserDefaults.standard.bool(forKey: offer.usedKey)
        if used { return false }

        let startedAt = UserDefaults.standard.double(forKey: offer.startedAtKey)
        if startedAt == 0 { return false }

        let now = Date().timeIntervalSince1970
        let elapsed = now - startedAt
        if elapsed >= offer.duration {
            UserDefaults.standard.set(true, forKey: offer.usedKey)
            AppAnalytics.log("offer_expired", params: [
                "offer_id": offer.identifier,
            ])
            return false
        }

        return true
    }

    /// Time remaining on the active offer, in seconds. Zero if not active.
    func remainingTime(for offer: OfferDefinition) -> TimeInterval {
        guard isOfferActive(offer) else { return 0 }
        let startedAt = UserDefaults.standard.double(forKey: offer.startedAtKey)
        let elapsed = Date().timeIntervalSince1970 - startedAt
        return max(0, offer.duration - elapsed)
    }

    // MARK: - DEV helpers

    /// Resets all offer state. DEV-only convenience.
    func resetAllOfferState() {
        for offer in OfferDefinition.allCases {
            UserDefaults.standard.removeObject(forKey: offer.startedAtKey)
            UserDefaults.standard.removeObject(forKey: offer.usedKey)
        }
    }

    /// Force-starts an offer NOW. DEV-only convenience.
    func devForceStart(_ offer: OfferDefinition) {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: offer.startedAtKey)
        UserDefaults.standard.set(false, forKey: offer.usedKey)
    }

    /// Returns a human-readable state string for DEV display.
    func devStateString(for offer: OfferDefinition) -> String {
        let used = UserDefaults.standard.bool(forKey: offer.usedKey)
        let startedAt = UserDefaults.standard.double(forKey: offer.startedAtKey)

        if used { return "used" }
        if startedAt == 0 { return "not started" }

        let remaining = remainingTime(for: offer)
        if remaining == 0 { return "expired (will mark used on next check)" }

        let hours = Int(remaining / 3600)
        let minutes = Int(remaining.truncatingRemainder(dividingBy: 3600) / 60)
        return "active, \(hours)h \(minutes)m left"
    }
}
