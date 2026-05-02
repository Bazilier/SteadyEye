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
    func schedule(_ kind: NotificationKind, in delay: TimeInterval) async {
        guard await hasPermission() else { return }

        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("\(kind.localizationPrefix).title",
                                          bundle: .main, comment: "")
        content.body = NSLocalizedString("\(kind.localizationPrefix).body",
                                         bundle: .main, comment: "")
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
