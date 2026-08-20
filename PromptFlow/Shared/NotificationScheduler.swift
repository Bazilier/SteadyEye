import Foundation
import UserNotifications

/// Shared local notification scheduler. Handles permission, scheduling,
/// and cancellation. All public methods are MainActor.
@MainActor
final class NotificationScheduler {
    static let shared = NotificationScheduler()
    private init() {}

    // MARK: - Permission

    /// Requests notification permission via the system prompt. Returns
    /// `true` on grant. Does NOT show a soft ask — call sites should
    /// gate on the soft ask UI.
    @discardableResult
    func requestPermissionIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        AppAnalytics.log("push_permission_requested", params: [
            "current_status": Self.statusString(settings.authorizationStatus)
        ])

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                AppAnalytics.log(granted ? "push_permission_granted" : "push_permission_denied")
                return granted
            } catch {
                AppAnalytics.log("push_permission_denied", params: [
                    "error_reason": String(describing: type(of: error))
                ])
                return false
            }
        @unknown default:
            return false
        }
    }

    /// True if the user has granted notification permission (any
    /// positive status — authorized, provisional, or ephemeral).
    func hasPermission() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    // MARK: - Scheduling

    /// Schedule a notification for the given kind to fire after `delay`
    /// seconds. If `delay <= 0`, fires immediately (still uses local
    /// notification path). Existing pending notification with the same
    /// identifier is replaced (idempotent re-schedule).
    ///
    /// `price` is the localized renewal price for kinds whose body quotes one.
    /// It is captured HERE, at schedule time, not read when the notification
    /// fires — which is correct: it is the price the user signed up at, and the
    /// content is built once, up to six days ahead of delivery.
    func schedule(_ kind: NotificationKind, in delay: TimeInterval, price: String? = nil) async {
        guard await hasPermission() else { return }

        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("\(kind.localizationPrefix).title",
                                          bundle: .main, comment: "")
        content.body = Self.body(for: kind, price: price)
        content.sound = .default
        content.userInfo = [
            NotificationDeepLink.userInfoKey: kind.deepLink.rawValue,
            "kind": kind.identifier,
        ]

        // 1s is the smallest valid interval for UNTimeIntervalNotificationTrigger.
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(delay, 1),
            repeats: false
        )

        let request = UNNotificationRequest(identifier: kind.identifier,
                                            content: content,
                                            trigger: trigger)

        do {
            UNUserNotificationCenter.current()
                .removePendingNotificationRequests(withIdentifiers: [kind.identifier])
            try await UNUserNotificationCenter.current().add(request)
            AppAnalytics.log("push_scheduled", params: [
                "kind": kind.identifier,
                "delay_sec": Int(delay)
            ])
        } catch {
            AppAnalytics.log("push_schedule_failed", params: [
                "kind": kind.identifier,
                "error_reason": String(describing: type(of: error))
            ])
        }
    }

    /// Cancel a pending notification by kind.
    func cancel(_ kind: NotificationKind) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [kind.identifier])
    }

    /// Cancel multiple kinds.
    func cancel(_ kinds: [NotificationKind]) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: kinds.map(\.identifier))
    }

    /// Cancel all pending notifications scheduled by this app.
    func cancelAll() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    // MARK: - Helpers

    /// Body copy for `kind`, filling the renewal price where the copy quotes one.
    ///
    /// When the price could not be resolved, this falls back to the
    /// `bodyNoPrice` variant — the same message with the price clause dropped —
    /// rather than to a literal amount. A hardcoded figure is correct for one
    /// storefront and wrong for every other, and is exactly what drifted before.
    private static func body(for kind: NotificationKind, price: String?) -> String {
        let key = "\(kind.localizationPrefix).body"
        // Only `.trialEnding24h` quotes a price. Every other kind's body is a
        // plain string and must never reach `String(format:)`, which would
        // mangle any literal `%` a translator introduced.
        guard kind == .trialEnding24h else {
            return NSLocalizedString(key, bundle: .main, comment: "")
        }
        guard let price else {
            return NSLocalizedString("\(key)NoPrice", bundle: .main, comment: "")
        }
        return String(format: NSLocalizedString(key, bundle: .main, comment: ""), price)
    }

    private static func statusString(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not_determined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }
}
