import Foundation
import StoreKit
import UIKit

/// Native App Store review prompt trigger. Apple HIG-compliant — no
/// pre-prompt ("are you happy?"), no custom rating UI, no satisfaction
/// gating. The system prompt is fired once on first onboarding
/// completion (provided camera + mic were granted at the call site);
/// iOS additionally throttles real renders to 3 times per Apple ID
/// per year regardless of how often we call.
@MainActor
enum ReviewPromptManager {
    /// Persisted timestamp of the last `requestReview` call, in
    /// `timeIntervalSince1970` seconds. Codebase convention is
    /// unprefixed camelCase (see `installDate`, `coldStartCountAfterOnboarding`,
    /// `notificationSoftAskShown` etc.).
    private static let lastPromptedKey = "lastReviewPromptAt"

    /// One-shot guard for the onboarding-completion trigger. Set on
    /// first qualifying call so re-entering onboarding (which the
    /// codebase doesn't currently expose, but is a defensive belt
    /// against future regressions) cannot re-fire the prompt.
    private static let hasRequestedReviewAfterOnboardingKey = "hasRequestedReviewAfterOnboarding"

    private static let cooldownBetweenPrompts: TimeInterval = 120 * 86400

    /// Call from `OnboardingView.finishOnboarding` after the
    /// `hasSeenOnboarding` flag flips, gated by camera+mic grant at
    /// the call site so users who bailed out of onboarding after
    /// denying permissions don't get the prompt.
    static func handleOnboardingCompleted() {
        guard !UserDefaults.standard.bool(forKey: hasRequestedReviewAfterOnboardingKey) else { return }

        if let lastPrompted = lastPromptedTimestamp() {
            let now = Date().timeIntervalSince1970
            guard (now - lastPrompted) >= cooldownBetweenPrompts else { return }
        }

        requestReview(trigger: "onboarding_completed")
        UserDefaults.standard.set(true, forKey: hasRequestedReviewAfterOnboardingKey)
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
