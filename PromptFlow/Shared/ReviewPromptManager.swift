import Foundation
import StoreKit
import UIKit

/// Native App Store review prompt trigger. Apple HIG-compliant — no
/// pre-prompt ("are you happy?"), no custom rating UI, no satisfaction
/// gating. The system prompt is fired exactly once per qualifying
/// recording-save event; iOS additionally throttles real renders to
/// 3 times per Apple ID per year regardless of how often we call.
@MainActor
enum ReviewPromptManager {
    /// Persisted timestamp of the last `requestReview` call, in
    /// `timeIntervalSince1970` seconds. Codebase convention is
    /// unprefixed camelCase (see `installDate`, `coldStartCountAfterOnboarding`,
    /// `notificationSoftAskShown` etc.).
    private static let lastPromptedKey = "lastReviewPromptAt"

    /// First-launch timestamp. Reuses the existing `installDate` flag
    /// stamped by `ContentView.onAppear` on first launch — no parallel
    /// install-tracking key.
    private static let firstInstallKey = "installDate"

    private static let minimumDaysSinceInstall: TimeInterval = 1 * 86400
    private static let cooldownBetweenPrompts: TimeInterval = 120 * 86400

    /// Call after a recording is successfully saved. `recordingsCount`
    /// is the total count AFTER the save (so first recording = 1).
    /// The "exactly 3" check fires the prompt once on the third save
    /// without re-firing on every subsequent save; iOS's per-year quota
    /// would discard the duplicates anyway, but gating client-side
    /// avoids burning the quota on noise.
    static func handleRecordingSaved(recordingsCount: Int) {
        guard shouldPrompt(recordingsCount: recordingsCount) else { return }
        requestReview()
    }

    private static func shouldPrompt(recordingsCount: Int) -> Bool {
        guard recordingsCount == 3 else { return false }

        guard let firstInstall = firstInstallTimestamp() else { return false }
        let now = Date().timeIntervalSince1970
        guard (now - firstInstall) >= minimumDaysSinceInstall else { return false }

        if let lastPrompted = lastPromptedTimestamp() {
            guard (now - lastPrompted) >= cooldownBetweenPrompts else { return false }
        }

        return true
    }

    private static func firstInstallTimestamp() -> Double? {
        let value = UserDefaults.standard.double(forKey: firstInstallKey)
        return value > 0 ? value : nil
    }

    private static func lastPromptedTimestamp() -> Double? {
        let value = UserDefaults.standard.double(forKey: lastPromptedKey)
        return value > 0 ? value : nil
    }

    private static func requestReview() {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else {
            return
        }
        SKStoreReviewController.requestReview(in: scene)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastPromptedKey)
        AppAnalytics.log("review_prompt_requested", params: ["recordings_count": 3])
    }
}
