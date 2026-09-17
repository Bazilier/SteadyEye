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

    /// Call once per SUCCESSFUL recording (finished + saved). Counting only —
    /// never presents. Every successful recording counts, including ones that
    /// yield their moment to a paywall.
    static func recordSuccessfulRecording() {
        let newCount = UserDefaults.standard.integer(forKey: successfulRecordingCountKey) + 1
        UserDefaults.standard.set(newCount, forKey: successfulRecordingCountKey)
    }

    /// Requests the review prompt if every condition holds: at least 2
    /// successful recordings, the 120-day cooldown elapsed, the arbiter
    /// allows it, and a foreground-active scene exists.
    ///
    /// A missing active scene returns WITHOUT touching `lastReviewPromptAt`,
    /// so the prompt is retried at the next save rather than being consumed by
    /// a request iOS never rendered.
    static func requestIfEligible() {
        guard UserDefaults.standard.integer(forKey: successfulRecordingCountKey) >= 2 else { return }

        if let lastPrompted = lastPromptedTimestamp() {
            let now = Date().timeIntervalSince1970
            guard (now - lastPrompted) >= cooldownBetweenPrompts else { return }
        }

        guard PromptArbiter.shared.canPresent(.reviewPrompt) else { return }

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
        PromptArbiter.shared.didPresent(.reviewPrompt)
        AppAnalytics.log("review_prompt_requested", params: ["trigger": trigger])
        // The system dialog reports nothing back, so release the arbiter after
        // a short window rather than leaving it latched for the session.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            PromptArbiter.shared.didDismiss()
        }
    }
}
