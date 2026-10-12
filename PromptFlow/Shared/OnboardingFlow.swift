import Foundation

/// Whether a new user is still inside the guided first run: onboarding, the
/// sample take, "What's your video about?" and the first take of their own
/// script, which ends in the one paywall the flow plans for.
///
/// While it is active, nothing automatic may interrupt it: `PromptArbiter`
/// denies every automatic prompt except `.onboardingPaywall`, the record
/// button skips the hard-paywall gate, and running out of free drafts shows
/// a message instead of a paywall.
///
/// Persisted, so a relaunch mid-flow stays protected. Started only by the
/// onboarding screen, so users who installed before it never enter it. A
/// flow that is never finished expires after `maxDuration`, so it cannot
/// switch the paywalls off for good.
enum OnboardingFlow {
    private static let startedAtKey = "onboardingFlowStartedAt"
    private static let finishedKey = "onboardingFlowFinished"
    static let maxDuration: TimeInterval = 72 * 60 * 60

    static var isActive: Bool {
        let defaults = UserDefaults.standard
        let startedAt = defaults.double(forKey: startedAtKey)
        guard startedAt > 0, !defaults.bool(forKey: finishedKey) else { return false }
        return Date().timeIntervalSince1970 - startedAt < maxDuration
    }

    /// Called when onboarding first appears. Does nothing once started, so
    /// reopening onboarding never extends the window.
    static func start() {
        let defaults = UserDefaults.standard
        guard defaults.double(forKey: startedAtKey) == 0 else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: startedAtKey)
        defaults.set(false, forKey: finishedKey)
    }

    static func finish(reason: String) {
        guard isActive else { return }
        UserDefaults.standard.set(true, forKey: finishedKey)
        AppAnalytics.log("onboarding_flow_finished", params: ["reason": reason])
    }

}
