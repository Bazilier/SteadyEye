import SwiftUI
import Combine

/// Cross-screen unread-count broadcaster for the chat feature.
/// Singleton because the tab bar (`ContentView`), the Settings row
/// (`SettingsView`), and the chat view itself all subscribe to the
/// same value. Mirrors the shared-singleton pattern used by
/// `SubscriptionManager.shared`.
@MainActor
final class ChatBadgeState: ObservableObject {
    static let shared = ChatBadgeState()

    @Published private(set) var unreadCount: Int = 0

    /// One-shot guard so the `chat_unread_badge_shown` analytics event
    /// fires once per process when the badge first becomes visible,
    /// not on every re-render.
    private var hasLoggedShownThisSession = false

    private init() {
        recalculate()
    }

    /// Recompute `unreadCount` from cached messages on disk. Call after
    /// fetching new messages or after marking-as-read.
    func recalculate() {
        let messages = ChatStorage.load()
        let next = ChatUnreadTracker.unreadCount(in: messages)
        unreadCount = next
        if next > 0, !hasLoggedShownThisSession {
            hasLoggedShownThisSession = true
            AppAnalytics.log("chat_unread_badge_shown", params: ["count": next])
        }
    }

    /// Mark all messages as read and zero the badge. Called when the
    /// chat view disappears.
    func markAllRead() {
        ChatUnreadTracker.markAllRead()
        unreadCount = 0
        // Reset the once-per-session guard so a fresh outbound burst
        // re-arms the analytics event later in the same session.
        hasLoggedShownThisSession = false
    }
}
