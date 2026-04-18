import AppTrackingTransparency
import AdSupport

@MainActor
enum ATTManager {
    /// Returns true if the system ATT prompt has never been shown to this user on this install.
    static var canRequestAuthorization: Bool {
        ATTrackingManager.trackingAuthorizationStatus == .notDetermined
    }

    /// Request ATT authorization. Safe to call even if already determined — system will no-op.
    /// Meta SDK 18 reads the result directly via ATTrackingManager; no further wiring needed.
    static func requestIfNeeded() async {
        guard canRequestAuthorization else { return }
        _ = await ATTrackingManager.requestTrackingAuthorization()
    }
}
