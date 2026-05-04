import Foundation

/// One-shot background fetcher for chat messages, fired on app
/// activation. Updates the JSON cache and `ChatBadgeState` so the
/// tab-bar and Settings-row badges reflect any replies that arrived
/// while the app was backgrounded. Fails silently — never surfaces
/// a UI error.
enum ChatBackgroundFetcher {
    @MainActor
    static func fetchInBackground() async {
        do {
            let serverMessages = try await ChatService.fetchMessages(since: nil)
            let cached = ChatStorage.load()
            let merged = mergeMessages(cached: cached, server: serverMessages)
            let priorServerCount = cached.filter { !$0.isLocal }.count
            ChatStorage.save(merged)
            ChatBadgeState.shared.recalculate()
            let newCount = max(0, serverMessages.count - priorServerCount)
            AppAnalytics.log("chat_background_fetch_completed", params: ["new_count": newCount])
        } catch {
            AppAnalytics.log("chat_background_fetch_failed", params: [
                "error": String(describing: error)
            ])
        }
    }

    /// Server is authoritative for any non-local message. Locally-
    /// optimistic rows (negative ids) survive the merge unless the
    /// server already reflects them, detected by matching text +
    /// inbound direction within a 60-second window — the same window
    /// the live chat view uses to reconcile optimistic sends.
    private static func mergeMessages(cached: [ChatMessage], server: [ChatMessage]) -> [ChatMessage] {
        var result = server
        let pendingLocals = cached.filter { $0.isLocal }
        for local in pendingLocals {
            let confirmed = server.contains { srv in
                srv.direction == .inbound &&
                srv.text == local.text &&
                abs(srv.createdAt.timeIntervalSince(local.createdAt)) < 60
            }
            if !confirmed {
                result.append(local)
            }
        }
        return result.sorted { $0.createdAt < $1.createdAt }
    }
}
