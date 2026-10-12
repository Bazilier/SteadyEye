#if DEV
import Foundation
import UserNotifications

/// DEV only: put the app back to a fresh install, then quit. Deletes every
/// script and recording (the SwiftData store and the files), chat storage,
/// caches, every UserDefaults key — onboarding, counters, one-shot flags,
/// settings, the AI proxy's fallback user id (so the backend sees a new user
/// with fresh free quotas) — and pending notifications.
///
/// Quits rather than patching live state: views hold `@AppStorage` values and
/// an open model container, and only a cold start rebuilds all of it the way
/// a new install would. System permissions (camera, microphone, photos,
/// tracking, notifications) are iOS's and survive; deleting the app resets
/// those.
enum DevReset {
    static func resetToFreshInstallAndQuit() -> Never {
        let fileManager = FileManager.default
        let directories: [FileManager.SearchPathDirectory] = [
            .documentDirectory, .applicationSupportDirectory, .cachesDirectory,
        ]
        for directory in directories {
            guard let root = fileManager.urls(for: directory, in: .userDomainMask).first,
                  let items = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            else { continue }
            items.forEach { try? fileManager.removeItem(at: $0) }
        }
        if let items = try? fileManager.contentsOfDirectory(
            at: fileManager.temporaryDirectory, includingPropertiesForKeys: nil
        ) {
            items.forEach { try? fileManager.removeItem(at: $0) }
        }

        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        UserDefaults.standard.synchronize()

        let notifications = UNUserNotificationCenter.current()
        notifications.removeAllPendingNotificationRequests()
        notifications.removeAllDeliveredNotifications()

        exit(0)
    }
}
#endif
