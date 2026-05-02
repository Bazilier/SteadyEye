import Foundation

/// Catalog of all offers the OfferEngine can activate and resolve.
/// Each case carries its own RevenueCat offering identifier, activation
/// duration window, and the AppStorage keys used to persist its state.
/// New offers (winback, time-limited, etc.) get added as new cases here
/// without touching OfferEngine logic.
enum OfferDefinition: String, CaseIterable {
    /// 50% off first period, shown after user dismisses standard paywall.
    /// Window: 3 days from first dismiss.
    case discount50AfterFirstDismiss = "discount_50_after_first_dismiss"

    /// Stable identifier used as AppStorage key prefix and as the
    /// `offer_id` analytics param.
    var identifier: String { rawValue }

    /// The RevenueCat offering identifier to fetch when this offer is
    /// active. Must match an offering configured in the RC dashboard.
    var revenueCatOfferingId: String {
        switch self {
        case .discount50AfterFirstDismiss: return "discount_50"
        }
    }

    /// Activation duration from the moment the offer is started.
    var duration: TimeInterval {
        switch self {
        case .discount50AfterFirstDismiss: return 3 * 24 * 60 * 60 // 3 days
        }
    }

    /// AppStorage keys for this offer's state.
    var startedAtKey: String { "offer_\(rawValue)_startedAt" }
    var usedKey: String { "offer_\(rawValue)_used" }
}
