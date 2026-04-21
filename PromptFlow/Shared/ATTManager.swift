import AppTrackingTransparency
import AdSupport

@MainActor
enum ATTManager {
    /// Feature switch: set to `true` to re-enable the ATT prompt on launch.
    /// Currently off because Meta Ads is postponed and Apple Search Ads
    /// doesn't need ATT. Info.plist key, Meta SDK integration, and the
    /// call site in SteadyEyeApp all stay wired — flipping this is the
    /// only change required to turn the prompt back on.
    static let isEnabled = false

    /// Returns true if the system ATT prompt has never been shown to this user on this install.
    static var canRequestAuthorization: Bool {
        ATTrackingManager.trackingAuthorizationStatus == .notDetermined
    }

    /// Request ATT authorization. Safe to call even if already determined — system will no-op.
    /// Meta SDK 18 reads the result directly via ATTrackingManager; no further wiring needed.
    static func requestIfNeeded() async {
        guard isEnabled, canRequestAuthorization else { return }
        _ = await ATTrackingManager.requestTrackingAuthorization()
    }
}
