import Foundation
import StoreKit
import UIKit

/// Native App Store review prompt trigger. Apple HIG-compliant — no
/// pre-prompt ("are you happy?"), no custom rating UI, no satisfaction
/// gating. Fired once on the user's 2nd successful recording (see
/// `handleSuccessfulRecording`); iOS additionally throttles real renders
/// to 3 times per Apple ID per year regardless of how often we call.
@MainActor
enum ReviewPromptManager {
    /// Persisted timestamp of the last `requestReview` call, in
    /// `timeIntervalSince1970` seconds. Codebase convention is
    /// unprefixed camelCase (see `installDate`, `coldStartCountAfterOnboarding`,
    /// `notificationSoftAskShown` etc.).
    private static let lastPromptedKey = "lastReviewPromptAt"

    /// Count of successful (finished + saved) recordings. Drives the
    /// usage-based review trigger.
    private static let successfulRecordingCountKey = "successful_recording_count"

    private static let cooldownBetweenPrompts: TimeInterval = 120 * 86400

    /// Call once per SUCCESSFUL recording (finished + saved). Increments the
    /// persistent counter and, on exactly the 2nd successful recording,
    /// requests an App Store review — subject to the shared 120-day cooldown
    /// and the foreground-active-scene requirement in `requestReview`. Counts
    /// other than 2 (1st, or 3rd+) do nothing, so this fires at most once.
    static func handleSuccessfulRecording() {
        let newCount = UserDefaults.standard.integer(forKey: successfulRecordingCountKey) + 1
        UserDefaults.standard.set(newCount, forKey: successfulRecordingCountKey)

        guard newCount == 2 else { return }

        // Respect the shared cooldown (e.g. if another trigger prompted recently).
        if let lastPrompted = lastPromptedTimestamp() {
            let now = Date().timeIntervalSince1970
            guard (now - lastPrompted) >= cooldownBetweenPrompts else { return }
        }

        requestReview(trigger: "second_successful_recording")
    }

    private static func lastPromptedTimestamp() -> Double? {
        let value = UserDefaults.standard.double(forKey: lastPromptedKey)
        return value > 0 ? value : nil
    }

    private static func requestReview(trigger: String) {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else {
            return
        }
        SKStoreReviewController.requestReview(in: scene)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastPromptedKey)
        AppAnalytics.log("review_prompt_requested", params: ["trigger": trigger])
    }
}
