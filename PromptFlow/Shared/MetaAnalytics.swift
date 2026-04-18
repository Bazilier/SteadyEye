import Foundation
import FBSDKCoreKit

enum MetaAnalytics {
    /// Called on every app launch. SDK deduplicates to a single install event internally.
    static func logAppActivation() {
        AppEvents.shared.activateApp()
    }

    /// Called when user completes first recording (not yet wired up anywhere)
    static func logFirstRecordingCompleted() {
        AppEvents.shared.logEvent(AppEvents.Name("first_recording_completed"))
    }
}
