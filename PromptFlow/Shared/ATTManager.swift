import AppTrackingTransparency
import AdSupport
import UIKit

@MainActor
enum ATTManager {
    /// Feature switch for the ATT prompt. Enabled for the AppsFlyer MMP
    /// integration: AppsFlyer benefits from IDFA access when the user grants
    /// tracking. The prompt is triggered at the end of onboarding (see
    /// `OnboardingView.finishOnboarding`). The MMP itself starts much earlier,
    /// at app launch, and holds its first session back until this prompt
    /// resolves, so the IDFA still reaches the install event when granted.
    static let isEnabled = true

    /// Returns true if the system ATT prompt has never been shown to this user on this install.
    static var canRequestAuthorization: Bool {
        ATTrackingManager.trackingAuthorizationStatus == .notDetermined
    }

    /// The IDFA to report to attribution partners. Returns the real IDFA only
    /// when tracking is authorized; otherwise the all-zeros default that
    /// RevenueCat requires — without it RC will not deliver events to the MMP.
    static var advertisingIdentifier: String {
        #if !DEV
        if ATTrackingManager.trackingAuthorizationStatus == .authorized {
            return ASIdentifierManager.shared().advertisingIdentifier.uuidString
        }
        #endif
        return "00000000-0000-0000-0000-000000000000"
    }

    /// Request ATT authorization. Safe to call even if already determined — system will no-op.
    /// Meta SDK 18 reads the result directly via ATTrackingManager; no further wiring needed.
    ///
    /// The onboarding flow presents the photos permission alert immediately
    /// before this runs. iOS silently drops an ATT request issued while another
    /// system alert is still dismissing, so we wait for the app to be cleanly
    /// foreground-active and let that alert settle before presenting ATT.
    static func requestIfNeeded() async {
        guard isEnabled, canRequestAuthorization else { return }
        await settleBeforePrompt()
        _ = await ATTrackingManager.requestTrackingAuthorization()
    }

    /// Ensure `.active` (up to ~2s) then a short settle for the prior system
    /// alert's dismiss animation, so the ATT prompt reliably presents.
    private static func settleBeforePrompt() async {
        var waitedMs = 0
        while UIApplication.shared.applicationState != .active, waitedMs < 2000 {
            try? await Task.sleep(for: .milliseconds(100))
            waitedMs += 100
        }
        try? await Task.sleep(for: .milliseconds(600))
    }
}
