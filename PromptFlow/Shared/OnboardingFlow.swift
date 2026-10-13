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

    // MARK: - Leaving and resuming

    /// The own script the flow drafted and is waiting to see recorded.
    static let flowScriptIDKey = "onboardingFlowScriptID"

    /// The user chose to skip the rest: the run counts as done, and every
    /// mark that would continue it is cleared, so nothing comes back.
    static func abandon(reason: String) {
        finish(reason: reason)
        let defaults = UserDefaults.standard
        for key in ["pendingOwnScriptAfterFirstTake", "ownTakeCoachPending",
                    "ownTakePaywallDue", flowScriptIDKey,
                    OwnTakePaywall.scriptIDKey, OwnTakePaywall.eyeContactKey] {
            defaults.removeObject(forKey: key)
        }
    }

    /// Where an unfinished run picks up after a relaunch.
    enum ResumeStep: Equatable {
        /// Only the planned paywall is left: shown without asking.
        case paywall
        case sampleTake
        case draft
        case ownTake(scriptID: UUID)
    }

    static func resumeStep(hasRecordedAnything: Bool) -> ResumeStep? {
        guard isActive else { return nil }
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "ownTakePaywallDue") { return .paywall }
        if !hasRecordedAnything { return .sampleTake }
        if defaults.bool(forKey: "pendingOwnScriptAfterFirstTake") { return .draft }
        if defaults.bool(forKey: "ownTakeCoachPending") {
            if let id = defaults.string(forKey: flowScriptIDKey).flatMap(UUID.init) {
                return .ownTake(scriptID: id)
            }
            return .draft
        }
        return nil
    }

}

/// Copy for the "leave the setup?" confirmation, shared by every place the
/// guided run can be walked out of.
enum LeaveSetupCopy {
    static var title: String {
        String(localized: "onboarding_flow.leave.title", defaultValue: "Skip the rest of the setup?", comment: "Alert title when the user tries to leave the guided first run (onboarding) before it is finished.")
    }
    static var message: String {
        String(localized: "onboarding_flow.leave.message", defaultValue: "You can always record and write scripts from the main screen.", comment: "Alert message when the user tries to leave the guided first run.")
    }
    static var skip: String {
        String(localized: "onboarding_flow.leave.skip", defaultValue: "Skip", comment: "Destructive button: leave the guided first run; it will not come back.")
    }
    static var stay: String {
        String(localized: "onboarding_flow.leave.stay", defaultValue: "Continue setup", comment: "Cancel button: stay in the guided first run.")
    }
}

/// The paywall after the first take of an own script shows that take: the
/// script in its pill and, when measured, the eye contact. The camera saves
/// both when it marks the paywall due; the list reads them, once, when it
/// shows it — possibly after a relaunch.
enum OwnTakePaywall {
    static let scriptIDKey = "ownTakePaywallScriptID"
    static let eyeContactKey = "ownTakePaywallEyeContact"
    /// Words handed to the pill, which cycles them.
    static let pillWordLimit = 40

    static func presentation(scripts: [Script]) -> PaywallPresentation {
        let defaults = UserDefaults.standard
        let id = defaults.string(forKey: scriptIDKey).flatMap(UUID.init)
        let content = scripts.first { $0.id == id }?.content ?? ""
        let words = content.split(whereSeparator: \.isWhitespace).prefix(pillWordLimit)
        let eyeContact = defaults.object(forKey: eyeContactKey) as? Double
        defaults.removeObject(forKey: scriptIDKey)
        defaults.removeObject(forKey: eyeContactKey)
        return PaywallPresentation(
            source: "first_own_take",
            pillPhrase: words.isEmpty ? nil : words.joined(separator: " "),
            eyeContact: eyeContact
        )
    }
}
