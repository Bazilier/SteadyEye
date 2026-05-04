import Foundation

enum ChatUnreadTracker {
    private static let lastReadKey = "steadyeye.chat.last_read_at"

    /// Timestamp of the most recent message the user has seen.
    /// `nil` means user has never opened the chat.
    static var lastReadAt: Date? {
        get {
            let timestamp = UserDefaults.standard.double(forKey: lastReadKey)
            return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
        }
        set {
            if let date = newValue {
                UserDefaults.standard.set(date.timeIntervalSince1970, forKey: lastReadKey)
            } else {
                UserDefaults.standard.removeObject(forKey: lastReadKey)
            }
        }
    }

    /// Mark all current messages as read by setting lastReadAt to now.
    static func markAllRead() {
        lastReadAt = Date()
    }

    /// Count of outbound (founder → user) messages whose createdAt is newer
    /// than `lastReadAt`. Inbound messages (the user's own) never contribute.
    /// If `lastReadAt` is nil (never opened), every outbound message counts.
    static func unreadCount(in messages: [ChatMessage]) -> Int {
        let outbound = messages.filter { $0.direction == .outbound }
        guard let lastRead = lastReadAt else { return outbound.count }
        return outbound.filter { $0.createdAt > lastRead }.count
    }
}
