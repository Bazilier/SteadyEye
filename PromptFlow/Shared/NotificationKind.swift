import Foundation

/// Catalog of all local notifications the app can schedule.
/// Each case carries its own identifier (used for cancel by ID), category,
/// and default delay if applicable.
enum NotificationKind: String, CaseIterable {
    case trialStarted = "trial_started"
    case trialDay5 = "trial_day_5"
    case trialEnding24h = "trial_ending_24h"
    case inactive3Days = "inactive_3_days"

    /// Stable identifier used by UNUserNotificationCenter.
    var identifier: String { rawValue }

    /// Localization key prefix. Body and title use `<prefix>.title` and `<prefix>.body`.
    var localizationPrefix: String { "push.\(rawValue)" }

    /// Deep link route the notification should open when tapped.
    var deepLink: NotificationDeepLink {
        switch self {
        case .trialStarted: return .openScripts
        case .trialDay5: return .openScripts
        case .trialEnding24h: return .openSettings
        case .inactive3Days: return .openScripts
        }
    }
}

/// Where a notification tap should land in-app.
enum NotificationDeepLink: String {
    case openScripts = "open_scripts"
    case openSettings = "open_settings"
    case openPaywall = "open_paywall"

    static let userInfoKey = "deep_link"

    /// Decode from the userInfo dictionary attached to a UNNotification.
    static func decode(from userInfo: [AnyHashable: Any]) -> NotificationDeepLink? {
        guard let raw = userInfo[userInfoKey] as? String else { return nil }
        return NotificationDeepLink(rawValue: raw)
    }
}
